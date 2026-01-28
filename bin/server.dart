import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';

// GLOBAL DATABASE POOL
late final Pool pool;

/// ===============================
/// 1. DATA FORMATTING HELPERS (CRITICAL)
/// ===============================

/// formats values for SQL (Manual Security for Simple Mode)
String dbVal(dynamic value) {
  if (value == null) return 'NULL';
  if (value is num) return value.toString();
  if (value is DateTime) return "'${value.toIso8601String()}'";

  // Escape single quotes for text safety
  String str = value.toString();
  return "'${str.replaceAll("'", "''")}'";
}

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
  // --- 1. FETCH PRODUCTS ---
  Future<Response> fetchProducts(Request request) async {
    try {
      final q = request.url.queryParameters;
      final int page = safeInt(q['page']) ?? 1;
      final int limit = safeInt(q['limit']) ?? 20;
      final String search = q['search']?.trim() ?? '';
      final String brand = q['brand']?.trim() ?? '';
      final int offset = (page - 1) * limit;

      String conditions = "1=1";
      if (search.isNotEmpty) {
        final safeSearch = dbVal('%$search%');
        conditions +=
            " AND (model ILIKE $safeSearch OR name ILIKE $safeSearch OR brand ILIKE $safeSearch)";
      }
      if (brand.isNotEmpty) {
        conditions += " AND brand = ${dbVal(brand)}";
      }

      final results = await Future.wait([
        pool.execute(
          "SELECT * FROM products WHERE $conditions ORDER BY id DESC LIMIT $limit OFFSET $offset",
        ),
        pool.execute(
          "SELECT COUNT(*)::int as count FROM products WHERE $conditions",
        ),
        pool.execute('''
            SELECT SUM(
              (COALESCE(sea_stock_qty, 0) * COALESCE(sea, 0)) +
              (COALESCE(air_stock_qty, 0) * COALESCE(air, 0)) +
              (COALESCE(local_qty, 0) * COALESCE(avg_purchase_price, 0))
            )::float8 as total_val
            FROM products WHERE $conditions
        '''),
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

  // --- 2. FETCH SHORTLIST ---
  Future<Response> fetchShortList(Request request) async {
    try {
      final q = request.url.queryParameters;
      if (q['all'] == 'true') {
        final res = await pool.execute(
          "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC",
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
          "SELECT * FROM products WHERE stock_qty <= alert_qty ORDER BY stock_qty ASC LIMIT $limit OFFSET $offset",
        ),
        pool.execute(
          "SELECT COUNT(*)::int as count FROM products WHERE stock_qty <= alert_qty",
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

  // --- 3. BULK INSERT ---
  Future<Response> insertProducts(Request request) async {
    try {
      final List products = await parseBody(request);
      await pool.runTx((session) async {
        for (final p in products) {
          final vals = _prepValues(p);
          await session.execute('''
            INSERT INTO products (
              name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
              shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
              sea_stock_qty, air_stock_qty, local_qty, alert_qty
            ) VALUES (
              ${vals['name']}, ${vals['category']}, ${vals['brand']}, ${vals['model']}, ${vals['weight']},
              ${vals['yuan']}, ${vals['sea']}, ${vals['air']}, ${vals['agent']}, ${vals['wholesale']},
              ${vals['shipmenttax']}, ${vals['shipmenttaxair']}, ${vals['shipmentdate']}, ${vals['shipmentno']},
              ${vals['currency']}, ${vals['stock_qty']}, ${vals['avg_purchase_price']},
              ${vals['sea_stock_qty']}, ${vals['air_stock_qty']}, ${vals['local_qty']}, ${vals['alert_qty']}
            )
          ''');
        }
      });
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 4. ADD SINGLE PRODUCT ---
  Future<Response> addSingleProduct(Request request) async {
    try {
      final p = await parseBody(request);
      final vals = _prepValues(p);
      final res = await pool.execute('''
          INSERT INTO products (
            name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
            shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
            sea_stock_qty, air_stock_qty, local_qty, alert_qty
          ) VALUES (
            ${vals['name']}, ${vals['category']}, ${vals['brand']}, ${vals['model']}, ${vals['weight']},
            ${vals['yuan']}, ${vals['sea']}, ${vals['air']}, ${vals['agent']}, ${vals['wholesale']},
            ${vals['shipmenttax']}, ${vals['shipmenttaxair']}, ${vals['shipmentdate']}, ${vals['shipmentno']},
            ${vals['currency']}, ${vals['stock_qty']}, ${vals['avg_purchase_price']},
            ${vals['sea_stock_qty']}, ${vals['air_stock_qty']}, ${vals['local_qty']}, ${vals['alert_qty']}
          ) RETURNING id
      ''');
      return Response.ok(jsonEncode({'id': res.first.toColumnMap()['id']}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 5 & 6. STOCK OPERATIONS ---
  Future<Response> addStockMixed(Request request) async =>
      await _processAddStock(await parseBody(request));

  Future<Response> bulkAddStockMixed(Request request) async {
    try {
      final List items = await parseBody(request);
      int count = 0;
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

  Future<Response> _processAddStock(Map<String, dynamic> p) async {
    final int id = safeInt(p['id']) ?? 0;
    final int incSea = safeInt(p['sea_qty']) ?? 0;
    final int incAir = safeInt(p['air_qty']) ?? 0;
    final int incLocal = safeInt(p['local_qty']) ?? 0;
    final double localPrice = safeDouble(p['local_price']) ?? 0.0;
    final DateTime? newShipDate = safeDate(p['shipmentdate']);

    final int totalIncoming = incSea + incAir + incLocal;
    if (totalIncoming <= 0 && newShipDate == null)
      return Response.ok('No changes');

    return await pool.runTx((session) async {
      final res = await session.execute(
        'SELECT * FROM products WHERE id = $id FOR UPDATE',
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
          : 0.0;

      String setClause =
          '''
          stock_qty = stock_qty + $totalIncoming,
          sea_stock_qty = sea_stock_qty + $incSea,
          air_stock_qty = air_stock_qty + $incAir,
          local_qty = COALESCE(local_qty, 0) + $incLocal,
          avg_purchase_price = $newAvg
      ''';

      if (newShipDate != null) {
        setClause += ", shipmentdate = ${dbVal(newShipDate)}";
      }

      await session.execute('UPDATE products SET $setClause WHERE id = $id');
      return Response.ok(jsonEncode({'success': true, 'new_avg': newAvg}));
    });
  }

  // --- 7. RECALCULATE PRICES ---
  Future<Response> recalculateAirSea(Request request) async {
    try {
      final p = await parseBody(request);
      final double newCurr = safeDouble(p['currency']) ?? 0.0;
      if (newCurr <= 0) return Response.badRequest(body: 'Invalid currency');

      await pool.execute('''
        UPDATE products SET
          currency = $newCurr,
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
                  (sea_stock_qty * ((yuan * $newCurr) + (weight * shipmenttax))) +
                  (air_stock_qty * ((yuan * $newCurr) + (weight * shipmenttaxair)))
                )
              ) / stock_qty
            ELSE 0
          END,
          sea = (yuan * $newCurr) + (weight * shipmenttax),
          air = (yuan * $newCurr) + (weight * shipmenttaxair)
        WHERE yuan > 0
      ''');
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 8. BULK UPDATE STOCK ---
  Future<Response> bulkUpdateStock(Request request) async {
    try {
      final body = await parseBody(request);
      final List updates = body['updates'] ?? [];

      await pool.runTx((session) async {
        for (final item in updates) {
          final int qty = safeInt(item['qty']) ?? 0;
          final int id = safeInt(item['id']) ?? 0;

          await session.execute('''
            UPDATE products SET
              stock_qty = GREATEST(0, stock_qty - $qty),
              local_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
                ELSE 0
              END,
              air_stock_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
                ELSE 0
              END,
              sea_stock_qty = CASE
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN sea_stock_qty
                ELSE sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + air_stock_qty))
              END
            WHERE id = $id
        ''');
        }
      });
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 9. UPDATE PRODUCT ---
  Future<Response> updateProduct(Request request, String idStr) async {
    try {
      final int id = int.parse(idStr);
      final vals = _prepValues(await parseBody(request));

      await pool.execute('''
        UPDATE products SET
          name=${vals['name']}, category=${vals['category']}, brand=${vals['brand']}, model=${vals['model']},
          weight=${vals['weight']}, yuan=${vals['yuan']}, sea=${vals['sea']}, air=${vals['air']},
          agent=${vals['agent']}, wholesale=${vals['wholesale']}, shipmenttax=${vals['shipmenttax']},
          shipmenttaxair=${vals['shipmenttaxair']}, shipmentdate=${vals['shipmentdate']},
          shipmentno=${vals['shipmentno']}, currency=${vals['currency']}, stock_qty=${vals['stock_qty']},
          avg_purchase_price=${vals['avg_purchase_price']}, sea_stock_qty=${vals['sea_stock_qty']},
          air_stock_qty=${vals['air_stock_qty']}, local_qty=${vals['local_qty']}, alert_qty=${vals['alert_qty']}
        WHERE id=$id
      ''');
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 10. DELETE PRODUCT ---
  Future<Response> deleteProduct(Request request, String idStr) async {
    try {
      final int id = int.parse(idStr);
      await pool.execute('DELETE FROM products WHERE id=$id');
      return Response.ok(jsonEncode({'success': true}));
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 11. ADD TO SERVICE ---
  Future<Response> addToService(Request request) async {
    try {
      final p = await parseBody(request);
      final int pid = safeInt(p['product_id']) ?? 0;
      final int qty = safeInt(p['qty']) ?? 0;
      final double cost = safeDouble(p['current_avg_price']) ?? 0.0;
      final String type = dbVal(safeStr(p['type']) ?? 'Repair');
      final String model = dbVal(safeStr(p['model']) ?? '');

      return await pool.runTx((session) async {
        await session.execute('''
            UPDATE products SET
              stock_qty = GREATEST(0, stock_qty - $qty),
              local_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty ELSE 0 END,
              air_stock_qty = CASE WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN air_stock_qty - ($qty - COALESCE(local_qty, 0)) ELSE 0 END,
              sea_stock_qty = CASE WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= $qty THEN sea_stock_qty ELSE sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + air_stock_qty)) END
            WHERE id = $pid
        ''');

        await session.execute('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES ($pid, $model, $qty, $type, $cost)
        ''');
        return Response.ok(jsonEncode({'success': true}));
      });
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // --- 12. RETURN FROM SERVICE ---
  Future<Response> returnFromService(Request request) async {
    try {
      final p = await parseBody(request);
      final int logId = safeInt(p['log_id']) ?? 0;
      final int qtyToReturn = safeInt(p['qty']) ?? 0;

      if (qtyToReturn <= 0) return Response.badRequest(body: "Invalid qty");

      return await pool.runTx((session) async {
        final res = await session.execute(
          'SELECT * FROM product_logs WHERE id = $logId',
        );
        if (res.isEmpty) return Response.notFound('Log not found');
        final log = res.first.toColumnMap();

        if (log['status'] == 'returned')
          return Response.badRequest(body: 'Already returned');

        final int pid = safeInt(log['product_id']) ?? 0;
        final int currentLogQty = safeInt(log['qty']) ?? 0;

        if (qtyToReturn > currentLogQty)
          return Response.badRequest(body: 'Cannot return. Limit exceeded.');

        await session.execute(
          'UPDATE products SET stock_qty = stock_qty + $qtyToReturn, local_qty = COALESCE(local_qty, 0) + $qtyToReturn WHERE id = $pid',
        );

        final int remainingQty = currentLogQty - qtyToReturn;
        if (remainingQty == 0) {
          await session.execute(
            "UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = $logId",
          );
        } else {
          await session.execute(
            "UPDATE product_logs SET qty = $remainingQty WHERE id = $logId",
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

  // --- 13. GET SERVICE LOGS ---
  Future<Response> getServiceLogs(Request request) async {
    try {
      final res = await pool.execute(
        "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC",
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

  // Helper to format map for SQL
  Map<String, String> _prepValues(Map<String, dynamic> p) {
    return {
      'name': dbVal(safeStr(p['name'])),
      'category': dbVal(safeStr(p['category'])),
      'brand': dbVal(safeStr(p['brand'])),
      'model': dbVal(safeStr(p['model'])),
      'weight': dbVal(safeDouble(p['weight'])),
      'yuan': dbVal(safeDouble(p['yuan'])),
      'sea': dbVal(safeDouble(p['sea'])),
      'air': dbVal(safeDouble(p['air'])),
      'agent': dbVal(safeDouble(p['agent'])),
      'wholesale': dbVal(safeDouble(p['wholesale'])),
      'shipmenttax': dbVal(safeDouble(p['shipmenttax'])),
      'shipmenttaxair': dbVal(safeDouble(p['shipmenttaxair']) ?? 0),
      'shipmentdate': dbVal(safeDate(p['shipmentdate'])),
      'shipmentno': dbVal(safeInt(p['shipmentno'])),
      'currency': dbVal(safeDouble(p['currency'])),
      'stock_qty': dbVal(safeInt(p['stock_qty']) ?? 0),
      'avg_purchase_price': dbVal(safeDouble(p['avg_purchase_price']) ?? 0),
      'sea_stock_qty': dbVal(safeInt(p['sea_stock_qty']) ?? 0),
      'air_stock_qty': dbVal(safeInt(p['air_stock_qty']) ?? 0),
      'local_qty': dbVal(safeInt(p['local_qty']) ?? 0),
      'alert_qty': dbVal(safeInt(p['alert_qty']) ?? 5),
    };
  }
}

/// ===============================
/// 3. MAIN SERVER
/// ===============================
void main() async {
  final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '5432');
  final dbName = Platform.environment['DB_NAME'] ?? 'postgres';
  final dbUser = Platform.environment['DB_USER'] ?? 'postgres';
  final dbPass = Platform.environment['DB_PASS'] ?? '';
  final serverPort = int.parse(Platform.environment['PORT'] ?? '8080');

  print("Connecting to $dbHost:$dbPort...");

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
      queryMode: QueryMode.simple, // IMPORTANT for Port 6543
    ),
  );

  final app = Router();
  final api = ApiController();

  app.get('/', (Request request) => Response.ok('✅ Active'));
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
