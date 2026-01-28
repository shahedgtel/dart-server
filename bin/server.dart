import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';

// GLOBAL DATABASE POOL
late final Pool pool;

/// ===============================
/// 1. HELPERS
/// ===============================

// Safely parse JSON body
Future<dynamic> parseBody(Request request) async {
  try {
    final content = await request.readAsString();
    return content.isNotEmpty ? jsonDecode(content) : {};
  } catch (e) {
    throw FormatException("Invalid JSON body");
  }
}

// JSON Date Serializer
Object? dateSerializer(Object? item) {
  if (item is DateTime) return item.toIso8601String();
  return item;
}

// Safe Type Casters
int? safeInt(dynamic v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
double? safeDouble(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
String? safeStr(dynamic v) => v?.toString().trim();
DateTime? safeDate(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());

// CORS Middleware
Middleware corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers':
                'Origin, Content-Type, Authorization',
          },
        );
      }
      final response = await handler(request);
      return response.change(
        headers: {...response.headers, 'Access-Control-Allow-Origin': '*'},
      );
    };
  };
}

/// ===============================
/// 2. CONTROLLER LOGIC
/// ===============================

class ApiController {
  // --- 1. FETCH PRODUCTS (GET /products) ---
  Future<Response> fetchProducts(Request request) async {
    try {
      final q = request.url.queryParameters;
      final int page = safeInt(q['page']) ?? 1;
      final int limit = safeInt(q['limit']) ?? 20;
      final String search = q['search']?.trim() ?? '';
      final String brand = q['brand']?.trim() ?? '';
      final int offset = (page - 1) * limit;

      // Base Queries
      String whereClause = "WHERE 1=1";
      final params = <String, dynamic>{};

      if (search.isNotEmpty) {
        whereClause +=
            " AND (model ILIKE @search OR name ILIKE @search OR brand ILIKE @search)";
        params['search'] = '%$search%';
      }
      if (brand.isNotEmpty) {
        whereClause += " AND brand = @brand";
        params['brand'] = brand;
      }

      // Parallel Execution: Get Data + Count + Total Value
      final results = await Future.wait([
        // 1. Get Rows
        pool.execute(
          Sql.named(
            "SELECT * FROM products $whereClause ORDER BY id DESC LIMIT @limit OFFSET @offset",
          ),
          parameters: {...params, 'limit': limit, 'offset': offset},
        ),
        // 2. Get Count
        pool.execute(
          Sql.named("SELECT COUNT(*)::int as count FROM products $whereClause"),
          parameters: params,
        ),
        // 3. Get Total Value (Math fixed in SQL)
        pool.execute(
          Sql.named('''
            SELECT SUM(
              (COALESCE(sea_stock_qty, 0) * COALESCE(sea, 0)) +
              (COALESCE(air_stock_qty, 0) * COALESCE(air, 0)) +
              (COALESCE(local_qty, 0) * COALESCE(avg_purchase_price, 0))
            )::float8 as total_val
            FROM products $whereClause
          '''),
          parameters: params,
        ),
      ]);

      return Response.ok(
        jsonEncode({
          'products': results[0].map((r) => r.toColumnMap()).toList(),
          'total': results[1].first.toColumnMap()['count'] ?? 0,
          'total_value': results[2].first.toColumnMap()['total_val'] ?? 0.0,
        }, toEncodable: dateSerializer),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 2. FETCH SHORTLIST (GET /products/shortlist) ---
  Future<Response> fetchShortList(Request request) async {
    try {
      final q = request.url.queryParameters;
      final bool exportAll = q['all'] == 'true';

      if (exportAll) {
        final res = await pool.execute(
          Sql.named(
            "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC",
          ),
        );
        return Response.ok(
          jsonEncode(
            res.map((r) => r.toColumnMap()).toList(),
            toEncodable: dateSerializer,
          ),
        );
      }

      final int page = safeInt(q['page']) ?? 1;
      final int limit = safeInt(q['limit']) ?? 20;
      final int offset = (page - 1) * limit;

      final results = await Future.wait([
        pool.execute(
          Sql.named(
            "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC LIMIT @limit OFFSET @offset",
          ),
          parameters: {'limit': limit, 'offset': offset},
        ),
        pool.execute(
          Sql.named(
            "SELECT COUNT(*)::int as count FROM products WHERE stock_qty <= alert_qty",
          ),
        ),
      ]);

      return Response.ok(
        jsonEncode({
          'products': results[0].map((r) => r.toColumnMap()).toList(),
          'total': results[1].first.toColumnMap()['count'] ?? 0,
        }, toEncodable: dateSerializer),
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 3. BULK INSERT (POST /products) ---
  Future<Response> insertProducts(Request request) async {
    try {
      final List products = await parseBody(request);

      await pool.runTx((session) async {
        final stmt = await session.prepare(
          Sql.named('''
          INSERT INTO products (
            name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
            shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
            sea_stock_qty, air_stock_qty, local_qty, alert_qty
          ) VALUES (
            @name, @category, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale,
            @shipmenttax, @shipmenttaxair, @shipmentdate, @shipmentno, @currency, @stock_qty, @avg_purchase_price,
            @sea_stock_qty, @air_stock_qty, @local_qty, @alert_qty
          )
        '''), // <--- CHANGED 0 TO @local_qty HERE
        );

        for (final p in products) {
          await stmt.run(_mapProductParams(p));
        }

        await stmt.dispose();
      });
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 4. ADD SINGLE PRODUCT (POST /products/add) ---
  Future<Response> addSingleProduct(Request request) async {
    try {
      final p = await parseBody(request);
      final res = await pool.execute(
        Sql.named('''
          INSERT INTO products (
            name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
            shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
            sea_stock_qty, air_stock_qty, local_qty, alert_qty
          ) VALUES (
            @name, @category, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale,
            @shipmenttax, @shipmenttaxair, @shipmentdate, @shipmentno, @currency, @stock_qty, @avg_purchase_price,
            @sea_stock_qty, @air_stock_qty, @local_qty, @alert_qty
          ) RETURNING id
      '''), // <--- CHANGED 0 TO @local_qty HERE
        parameters: _mapProductParams(p),
      );

      return Response.ok(jsonEncode({'id': res.first.toColumnMap()['id']}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 5. ADD STOCK MIXED (POST /products/add-stock) ---
  // Critical Math Fix: Locked transaction to calculate Average Price accurately
  Future<Response> addStockMixed(Request request) async {
    try {
      final p = await parseBody(request);
      return await _processAddStock(p);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 6. BULK ADD STOCK (POST /products/bulk-add-stock) ---
  Future<Response> bulkAddStockMixed(Request request) async {
    try {
      final List items = await parseBody(request);
      int count = 0;

      // Process strictly sequentially to prevent deadlocks
      for (final item in items) {
        await _processAddStock(item);
        count++;
      }
      return Response.ok(jsonEncode({'success': true, 'processed': count}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // Helper for Stock Math (Used by Single and Bulk)
  Future<Response> _processAddStock(Map<String, dynamic> p) async {
    final int id = safeInt(p['id']) ?? 0;
    final int incSea = safeInt(p['sea_qty']) ?? 0;
    final int incAir = safeInt(p['air_qty']) ?? 0;
    final int incLocal = safeInt(p['local_qty']) ?? 0;
    final double localPrice = safeDouble(p['local_price']) ?? 0.0;

    // Optional: Update shipment date if provided
    final DateTime? newShipDate = safeDate(p['shipmentdate']);

    final int totalIncoming = incSea + incAir + incLocal;
    if (totalIncoming <= 0 && newShipDate == null) {
      return Response.ok('No changes');
    }

    return await pool.runTx((session) async {
      // LOCK ROW FOR UPDATE
      final res = await session.execute(
        Sql.named('SELECT * FROM products WHERE id = @id FOR UPDATE'),
        parameters: {'id': id},
      );

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      final double oldQty = safeDouble(row['stock_qty']) ?? 0.0;
      final double oldAvg = safeDouble(row['avg_purchase_price']) ?? 0.0;
      final double yuan = safeDouble(row['yuan']) ?? 0.0;
      final double curr = safeDouble(row['currency']) ?? 0.0;
      final double weight = safeDouble(row['weight']) ?? 0.0;
      final double tax = safeDouble(row['shipmenttax']) ?? 0.0;
      final double taxAir = safeDouble(row['shipmenttaxair']) ?? 0.0;

      // Calculate Costs based on CURRENT DB values
      final double seaUnitCost = (yuan * curr) + (weight * tax);
      final double airUnitCost = (yuan * curr) + (weight * taxAir);

      final double totalValueIncoming =
          (incSea * seaUnitCost) +
          (incAir * airUnitCost) +
          (incLocal * localPrice);

      final double totalValueOld = oldQty * oldAvg;
      final double newTotalQty = oldQty + totalIncoming;

      final double newAvg = newTotalQty > 0
          ? (totalValueOld + totalValueIncoming) / newTotalQty
          : 0.0; // Reset avg if stock hits 0

      // Dynamic Query construction
      String updateSql = '''
          UPDATE products SET
            stock_qty = stock_qty + @totalIncoming,
            sea_stock_qty = sea_stock_qty + @incSea,
            air_stock_qty = air_stock_qty + @incAir,
            local_qty = COALESCE(local_qty, 0) + @incLocal,
            avg_purchase_price = @newAvg
      ''';

      final params = <String, dynamic>{
        'totalIncoming': totalIncoming,
        'incSea': incSea,
        'incAir': incAir,
        'incLocal': incLocal,
        'newAvg': newAvg,
        'id': id,
      };

      if (newShipDate != null) {
        updateSql += ', shipmentdate = @sDate';
        params['sDate'] = newShipDate;
      }

      updateSql += ' WHERE id = @id';

      await session.execute(Sql.named(updateSql), parameters: params);

      return Response.ok(
        jsonEncode({
          'success': true,
          'new_avg': newAvg,
          'added_total': totalIncoming,
        }),
      );
    });
  }

  // --- 7. RECALCULATE AIR/SEA (PUT /products/recalculate-prices) ---
  Future<Response> recalculateAirSea(Request request) async {
    try {
      final p = await parseBody(request);
      final double newCurr = safeDouble(p['currency']) ?? 0.0;

      if (newCurr <= 0) return Response.badRequest(body: 'Invalid currency');

      // Optimized SQL Update
      await pool.execute(
        Sql.named('''
        UPDATE products SET
          currency = @newCurr,
         
          -- Recalculate Weighted Average
          avg_purchase_price = CASE
            WHEN stock_qty > 0 THEN
              (
                (
                  (stock_qty * avg_purchase_price) -
                  (
                    (sea_stock_qty * ((yuan * currency) + (weight * shipmenttax))) +
                    (air_stock_qty * ((yuan * currency) + (weight * shipmenttaxair)))
                  )
                )
                +
                (
                  (sea_stock_qty * ((yuan * @newCurr) + (weight * shipmenttax))) +
                  (air_stock_qty * ((yuan * @newCurr) + (weight * shipmenttaxair)))
                )
              ) / stock_qty
            ELSE 0
          END,

          -- Update Base Costs
          sea = (yuan * @newCurr) + (weight * shipmenttax),
          air = (yuan * @newCurr) + (weight * shipmenttaxair)

        WHERE yuan > 0
      '''),
        parameters: {'newCurr': newCurr},
      );

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 8. BULK UPDATE STOCK (POS CHECKOUT) ---
  Future<Response> bulkUpdateStock(Request request) async {
    try {
      final body = await parseBody(request);
      final List updates = body['updates'] ?? [];

      await pool.runTx((session) async {
        final stmt = await session.prepare(
          Sql.named('''
            UPDATE products SET
              stock_qty = GREATEST(0, stock_qty - @qty),
             
              local_qty = CASE
                WHEN COALESCE(local_qty, 0) >= @qty THEN local_qty - @qty
                ELSE 0
              END,

              air_stock_qty = CASE
                WHEN COALESCE(local_qty, 0) >= @qty THEN air_stock_qty
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN air_stock_qty - (@qty - COALESCE(local_qty, 0))
                ELSE 0
              END,

              sea_stock_qty = CASE
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN sea_stock_qty
                ELSE sea_stock_qty - (@qty - (COALESCE(local_qty, 0) + air_stock_qty))
              END
            WHERE id = @id
        '''),
        );

        for (final item in updates) {
          // FIX: Pass the map directly, without "parameters:" name
          await stmt.run({
            'qty': safeInt(item['qty']) ?? 0,
            'id': safeInt(item['id']),
          });
        }

        await stmt.dispose();
      });

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 9. UPDATE PRODUCT (PUT /products/<id>) ---
  Future<Response> updateProduct(Request request, String idStr) async {
    try {
      final int id = int.parse(idStr);
      final p = await parseBody(request);

      await pool.execute(
        Sql.named('''
        UPDATE products SET
          name=@name, category=@category, brand=@brand, model=@model, weight=@weight, yuan=@yuan,
          sea=@sea, air=@air, agent=@agent, wholesale=@wholesale,
          shipmenttax=@shipmenttax, shipmenttaxair=@shipmenttaxair, shipmentdate=@shipmentdate,
          shipmentno=@shipmentno, currency=@currency, stock_qty=@stock_qty, avg_purchase_price=@avg_purchase_price,
          sea_stock_qty=@sea_stock_qty, air_stock_qty=@air_stock_qty, local_qty=@local_qty,
          alert_qty=@alert_qty
        WHERE id=@id
      '''),
        parameters: {..._mapProductParams(p), 'id': id},
      );

      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 10. DELETE PRODUCT (DELETE /products/<id>) ---
  Future<Response> deleteProduct(Request request, String idStr) async {
    try {
      final int id = int.parse(idStr);
      await pool.execute(
        Sql.named('DELETE FROM products WHERE id=@id'),
        parameters: {'id': id},
      );
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 11. ADD TO SERVICE (POST /service/add) ---
  Future<Response> addToService(Request request) async {
    try {
      final p = await parseBody(request);
      final int pid = safeInt(p['product_id']) ?? 0;
      final int qty = safeInt(p['qty']) ?? 0;
      final double cost = safeDouble(p['current_avg_price']) ?? 0.0;
      final String type = safeStr(p['type']) ?? 'Repair';
      final String model = safeStr(p['model']) ?? '';

      return await pool.runTx((session) async {
        // Decrease from Stock (Logic similar to POS checkout)
        await session.execute(
          Sql.named('''
            UPDATE products SET
              stock_qty = GREATEST(0, stock_qty - @qty),
              local_qty = CASE WHEN COALESCE(local_qty, 0) >= @qty THEN local_qty - @qty ELSE 0 END,
              air_stock_qty = CASE WHEN COALESCE(local_qty, 0) >= @qty THEN air_stock_qty WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN air_stock_qty - (@qty - COALESCE(local_qty, 0)) ELSE 0 END,
              sea_stock_qty = CASE WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN sea_stock_qty ELSE sea_stock_qty - (@qty - (COALESCE(local_qty, 0) + air_stock_qty)) END
            WHERE id = @pid
        '''),
          parameters: {'qty': qty, 'pid': pid},
        );

        await session.execute(
          Sql.named('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES (@pid, @model, @qty, @type, @cost)
        '''),
          parameters: {
            'pid': pid,
            'model': model,
            'qty': qty,
            'type': type,
            'cost': cost,
          },
        );

        return Response.ok(jsonEncode({'success': true}));
      });
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 12. RETURN FROM SERVICE (POST /service/return) ---
  Future<Response> returnFromService(Request request) async {
    try {
      final p = await parseBody(request);
      final int logId = safeInt(p['log_id']) ?? 0;
      final int qtyToReturn = safeInt(p['qty']) ?? 0;

      if (qtyToReturn <= 0) return Response.badRequest(body: "Invalid qty");

      return await pool.runTx((session) async {
        final res = await session.execute(
          Sql.named('SELECT * FROM product_logs WHERE id = @id'),
          parameters: {'id': logId},
        );
        if (res.isEmpty) return Response.notFound('Log not found');
        final log = res.first.toColumnMap();

        if (log['status'] == 'returned') {
          return Response.badRequest(body: 'Already returned');
        }

        final int pid = safeInt(log['product_id']) ?? 0;
        final int currentLogQty = safeInt(log['qty']) ?? 0;

        if (qtyToReturn > currentLogQty) {
          return Response.badRequest(
            body: 'Cannot return $qtyToReturn. Only $currentLogQty in service.',
          );
        }

        // Add back to stock (Assume added to Local first)
        await session.execute(
          Sql.named(
            'UPDATE products SET stock_qty = stock_qty + @qty, local_qty = COALESCE(local_qty, 0) + @qty WHERE id = @pid',
          ),
          parameters: {'qty': qtyToReturn, 'pid': pid},
        );

        final int remainingQty = currentLogQty - qtyToReturn;

        if (remainingQty == 0) {
          await session.execute(
            Sql.named(
              "UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = @id",
            ),
            parameters: {'id': logId},
          );
        } else {
          await session.execute(
            Sql.named("UPDATE product_logs SET qty = @qty WHERE id = @id"),
            parameters: {'qty': remainingQty, 'id': logId},
          );
        }
        return Response.ok(jsonEncode({'success': true}));
      });
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 13. GET SERVICE LOGS (GET /service/list) ---
  Future<Response> getServiceLogs(Request request) async {
    try {
      final res = await pool.execute(
        Sql.named(
          "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC",
        ),
      );
      return Response.ok(
        jsonEncode(
          res.map((r) => r.toColumnMap()).toList(),
          toEncodable: dateSerializer,
        ),
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // Helper for Product Params
  Map<String, dynamic> _mapProductParams(Map<String, dynamic> p) {
    return {
      'name': safeStr(p['name']),
      'category': safeStr(p['category']),
      'brand': safeStr(p['brand']),
      'model': safeStr(p['model']),
      'weight': safeDouble(p['weight']),
      'yuan': safeDouble(p['yuan']),
      'sea': safeDouble(p['sea']),
      'air': safeDouble(p['air']),
      'agent': safeDouble(p['agent']),
      'wholesale': safeDouble(p['wholesale']),
      'shipmenttax': safeDouble(p['shipmenttax']),
      'shipmenttaxair': safeDouble(p['shipmenttaxair']) ?? 0,
      'shipmentdate': safeDate(p['shipmentdate']),
      'shipmentno': safeInt(p['shipmentno']),
      'currency': safeDouble(p['currency']),
      'stock_qty': safeInt(p['stock_qty']) ?? 0,
      'avg_purchase_price': safeDouble(p['avg_purchase_price']) ?? 0,
      'sea_stock_qty': safeInt(p['sea_stock_qty']) ?? 0,
      'air_stock_qty': safeInt(p['air_stock_qty']) ?? 0,
      'local_qty': safeInt(p['local_qty']) ?? 0,
      'alert_qty': safeInt(p['alert_qty']) ?? 5,
    };
  }
}

/// ===============================
/// 3. MAIN SERVER
/// ===============================
void main() async {
  // RENDER.COM / SUPABASE ENV VARS
  // Use Platform.environment so it works on Render automatically
  final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '5432');
  final dbName = Platform.environment['DB_NAME'] ?? 'postgres';
  final dbUser = Platform.environment['DB_USER'] ?? 'postgres';
  final dbPass = Platform.environment['DB_PASS'] ?? '';
  final serverPort = int.parse(Platform.environment['PORT'] ?? '8080');

  print("Connecting to $dbHost:$dbPort...");

  // Connection Pool Setup (Future Proof)
  pool = Pool.withEndpoints(
    [
      Endpoint(
        host: dbHost,
        port: dbPort,
        database: dbName,
        username: dbUser,
        password: dbPass,
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 15,
      sslMode: SslMode.require,
      // QueryMode.extended allows Prepared Statements (Faster & Safer)
      // If using Supabase Port 6543, you might need QueryMode.simple
      queryMode: QueryMode.extended,
    ),
  );

  // Router Setup
  final app = Router();
  final api = ApiController();

  app.get('/', (Request request) => Response.ok('Active Connection'));
  // 13 Routes Mapped
  app.get('/products', api.fetchProducts);
  app.get('/products/shortlist', api.fetchShortList);
  app.post('/products', api.insertProducts);
  app.post('/products/add', api.addSingleProduct);
  app.post('/products/add-stock', api.addStockMixed);
  app.post('/products/bulk-add-stock', api.bulkAddStockMixed);
  app.put('/products/recalculate-prices', api.recalculateAirSea);
  app.put('/products/bulk-update-stock', api.bulkUpdateStock);
  app.put('/products/<id>', api.updateProduct);
  app.delete('/products/<id>', api.deleteProduct);
  app.post('/service/add', api.addToService);
  app.post('/service/return', api.returnFromService);
  app.get('/service/list', api.getServiceLogs);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(app.call);

  await shelf_io.serve(handler, '0.0.0.0', serverPort);
  print('🚀 Server running on port $serverPort');
}
