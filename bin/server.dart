import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

late final Pool pool;

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

num? safeNum(dynamic v) => v is num ? v : num.tryParse(v?.toString() ?? '');
String? safeStr(dynamic v) =>
    v?.toString().trim().isEmpty ?? true ? null : v.toString().trim();

/// ===============================
/// 1. BULK INSERT
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    final List products = jsonDecode(await request.readAsString());
    await pool.runTx((session) async {
      for (final p in products) {
        await session.execute(
          Sql.named('''
            INSERT INTO products (
              name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
              shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
              sea_stock_qty, air_stock_qty, local_qty
            ) VALUES (
              @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale,
              @tax, @taxAir, @sDate, @sNo, @curr, @stock, @avg, @sStock, @aStock, 0
            )
          '''),
          parameters: {
            'name': safeStr(p['name']),
            'cat': safeStr(p['category']),
            'brand': safeStr(p['brand']),
            'model': safeStr(p['model']),
            'weight': safeNum(p['weight']),
            'yuan': safeNum(p['yuan']),
            'sea': safeNum(p['sea']),
            'air': safeNum(p['air']),
            'agent': safeNum(p['agent']),
            'wholesale': safeNum(p['wholesale']),
            'tax': safeNum(p['shipmenttax']),
            'taxAir': safeNum(p['shipmenttaxair']) ?? 0, // NEW FIELD
            'sDate': safeStr(p['shipmentdate']), // NEW FIELD
            'sNo': safeNum(p['shipmentno']),
            'curr': safeNum(p['currency']),
            'stock': safeNum(p['stock_qty']) ?? 0,
            'avg': safeNum(p['avg_purchase_price']) ?? 0,
            'sStock': safeNum(p['sea_stock_qty']) ?? 0,
            'aStock': safeNum(p['air_stock_qty']) ?? 0,
          },
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 2. ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final res = await pool.execute(
      Sql.named('''
        INSERT INTO products (
          name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
          shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency, stock_qty, avg_purchase_price,
          sea_stock_qty, air_stock_qty, local_qty
        ) VALUES (
          @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale,
          @tax, @taxAir, @sDate, @sNo, @curr, @stock, @avg, @sStock, @aStock, 0
        ) RETURNING id
      '''),
      parameters: {
        'name': safeStr(p['name']),
        'cat': safeStr(p['category']),
        'brand': safeStr(p['brand']),
        'model': safeStr(p['model']),
        'weight': safeNum(p['weight']),
        'yuan': safeNum(p['yuan']),
        'sea': safeNum(p['sea']),
        'air': safeNum(p['air']),
        'agent': safeNum(p['agent']),
        'wholesale': safeNum(p['wholesale']),
        'tax': safeNum(p['shipmenttax']),
        'taxAir': safeNum(p['shipmenttaxair']) ?? 0, // NEW FIELD
        'sDate': safeStr(p['shipmentdate']), // NEW FIELD
        'sNo': safeNum(p['shipmentno']),
        'curr': safeNum(p['currency']),
        'stock': safeNum(p['stock_qty']) ?? 0,
        'avg': safeNum(p['avg_purchase_price']) ?? 0,
        'sStock': safeNum(p['sea_stock_qty']) ?? 0,
        'aStock': safeNum(p['air_stock_qty']) ?? 0,
      },
    );
    return Response.ok(jsonEncode({'id': res.first.toColumnMap()['id']}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 3. UPDATE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());
    await pool.execute(
      Sql.named('''
        UPDATE products SET
          name=@name, category=@cat, brand=@brand, model=@model, weight=@weight, yuan=@yuan,
          sea=@sea, air=@air, agent=@agent, wholesale=@wholesale,
          shipmenttax=@tax, shipmenttaxair=@taxAir, shipmentdate=@sDate,
          shipmentno=@sNo, currency=@curr, stock_qty=@stock, avg_purchase_price=@avg,
          sea_stock_qty=@sStock, air_stock_qty=@aStock, local_qty=@local
        WHERE id=@id
      '''),
      parameters: {
        'id': id,
        'name': safeStr(p['name']),
        'cat': safeStr(p['category']),
        'brand': safeStr(p['brand']),
        'model': safeStr(p['model']),
        'weight': safeNum(p['weight']),
        'yuan': safeNum(p['yuan']),
        'sea': safeNum(p['sea']),
        'air': safeNum(p['air']),
        'agent': safeNum(p['agent']),
        'wholesale': safeNum(p['wholesale']),
        'tax': safeNum(p['shipmenttax']),
        'taxAir': safeNum(p['shipmenttaxair']), // NEW FIELD
        'sDate': safeStr(p['shipmentdate']), // NEW FIELD
        'sNo': safeNum(p['shipmentno']),
        'curr': safeNum(p['currency']),
        'stock': safeNum(p['stock_qty']),
        'avg': safeNum(p['avg_purchase_price']),
        'sStock': safeNum(p['sea_stock_qty']),
        'aStock': safeNum(p['air_stock_qty']),
        'local': safeNum(p['local_qty']),
      },
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 4. ADD STOCK (MIXED) - (AIR=TAX_AIR, SEA=TAX)
/// ===============================
Future<Response> addStockMixed(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());

    final int id = safeNum(p['id'])?.toInt() ?? 0;
    final int incSea = safeNum(p['sea_qty'])?.toInt() ?? 0;
    final int incAir = safeNum(p['air_qty'])?.toInt() ?? 0;
    final int incLocal = safeNum(p['local_qty'])?.toInt() ?? 0;
    final double localPrice = safeNum(p['local_price'])?.toDouble() ?? 0.0;

    final int totalIncoming = incSea + incAir + incLocal;
    if (totalIncoming <= 0) return Response.badRequest(body: 'Qty must be > 0');

    return await pool.runTx((session) async {
      final res = await session.execute(
        Sql.named(
          'SELECT stock_qty, avg_purchase_price, yuan, currency, weight, shipmenttax, shipmenttaxair FROM products WHERE id = @id',
        ),
        parameters: {'id': id},
      );

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      final double oldQty = safeNum(row['stock_qty'])?.toDouble() ?? 0.0;
      final double oldAvg =
          safeNum(row['avg_purchase_price'])?.toDouble() ?? 0.0;

      final double yuan = safeNum(row['yuan'])?.toDouble() ?? 0.0;
      final double curr = safeNum(row['currency'])?.toDouble() ?? 0.0;
      final double weight = safeNum(row['weight'])?.toDouble() ?? 0.0;
      final double tax = safeNum(row['shipmenttax'])?.toDouble() ?? 0.0;
      final double taxAir =
          safeNum(row['shipmenttaxair'])?.toDouble() ?? 0.0; // UPDATED

      // --- LOGIC: AIR=TAX_AIR, SEA=TAX ---
      final double seaUnitCost = (yuan * curr) + (weight * tax);
      // UPDATED: Replaced hardcoded 700 with taxAir from DB
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

      await session.execute(
        Sql.named('''
          UPDATE products SET
            stock_qty = stock_qty + @incTotal,
            sea_stock_qty = sea_stock_qty + @incSea,
            air_stock_qty = air_stock_qty + @incAir,
            local_qty = COALESCE(local_qty, 0) + @incLocal,
            avg_purchase_price = @newAvg
          WHERE id = @id
        '''),
        parameters: {
          'id': id,
          'incTotal': totalIncoming,
          'incSea': incSea,
          'incLocal': incLocal,
          'incAir': incAir,
          'newAvg': newAvg,
        },
      );

      return Response.ok(
        jsonEncode({
          'success': true,
          'new_avg': newAvg,
          'added_total': totalIncoming,
        }),
      );
    });
  } catch (e) {
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 5. BULK CURRENCY UPDATE (PROTECT LOCAL + AIR=TAX_AIR)
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final double newCurr = safeNum(data['currency'])?.toDouble() ?? 0.0;

    if (newCurr <= 0) {
      return Response.badRequest(body: 'Valid currency required');
    }

    // UPDATED: Replaced hardcoded 700 with shipmenttaxair column
    await pool.execute(
      Sql.named('''
        UPDATE products SET
          currency = @newC,

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
                  (sea_stock_qty * ((yuan * @newC) + (weight * shipmenttax))) +
                  (air_stock_qty * ((yuan * @newC) + (weight * shipmenttaxair)))
                )
              ) / stock_qty
            ELSE 0
          END,

          sea = (yuan * @newC) + (weight * shipmenttax),
          air = (yuan * @newC) + (weight * shipmenttaxair)

        WHERE yuan > 0
      '''),
      parameters: {'newC': newCurr},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. POS CHECKOUT (WATERFALL)
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    await pool.runTx((session) async {
      for (final item in updates) {
        int qty = safeNum(item['qty'])?.toInt() ?? 0;
        int id = safeNum(item['id'])?.toInt() ?? 0;

        await session.execute(
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
          parameters: {'id': id, 'qty': qty},
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 7. FETCH PRODUCTS
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final q = request.url.queryParameters;
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final search = q['search']?.trim() ?? '';
    final offset = (page - 1) * limit;

    String where = "";
    final countParams = <String, dynamic>{};
    final selectParams = <String, dynamic>{'l': limit, 'o': offset};

    if (search.isNotEmpty) {
      where = "WHERE model ILIKE @s OR name ILIKE @s OR brand ILIKE @s";
      countParams['s'] = '%$search%';
      selectParams['s'] = '%$search%';
    }

    final totalRes = await pool.execute(
      Sql.named("SELECT COUNT(*)::int FROM products $where"),
      parameters: countParams,
    );
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    final results = await pool.execute(
      Sql.named(
        "SELECT * FROM products $where ORDER BY id DESC LIMIT @l OFFSET @o",
      ),
      parameters: selectParams,
    );

    final List<Map<String, dynamic>> list = results
        .map((r) => r.toColumnMap())
        .toList();

    return Response.ok(
      jsonEncode({'products': list, 'total': total}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 8. DELETE
/// ===============================
Future<Response> deleteProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    await pool.execute(
      Sql.named('DELETE FROM products WHERE id=@id'),
      parameters: {'id': id},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 9. SERVICE LOGIC (NEW FEATURES)
/// ===============================

// A. Move to Service (Deduct from Stock, Create Log)
Future<Response> addToService(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    return await pool.runTx((session) async {
      // 1. Deduct Stock using Waterfall logic (Deduct from Local/Air/Sea)
      // We reuse the update logic block manually here for single item
      await session.execute(
        Sql.named('''
          UPDATE products SET
            stock_qty = GREATEST(0, stock_qty - @qty),
            local_qty = CASE WHEN COALESCE(local_qty, 0) >= @qty THEN local_qty - @qty ELSE 0 END,
            air_stock_qty = CASE WHEN COALESCE(local_qty, 0) >= @qty THEN air_stock_qty WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN air_stock_qty - (@qty - COALESCE(local_qty, 0)) ELSE 0 END,
            sea_stock_qty = CASE WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN sea_stock_qty ELSE sea_stock_qty - (@qty - (COALESCE(local_qty, 0) + air_stock_qty)) END
          WHERE id = @id
        '''),
        parameters: {'id': p['product_id'], 'qty': p['qty']},
      );

      // 2. Create Log
      await session.execute(
        Sql.named('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES (@id, @model, @qty, @type, @cost)
        '''),
        parameters: {
          'id': p['product_id'],
          'model': p['model'],
          'qty': p['qty'],
          'type': p['type'], // 'service' or 'damage'
          'cost': p['current_avg_price'],
        },
      );

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// B. Return from Service (Add to Local Stock, Close Log)
Future<Response> returnFromService(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    return await pool.runTx((session) async {
      // Get Log
      final res = await session.execute(
        Sql.named('SELECT * FROM product_logs WHERE id = @id'),
        parameters: {'id': p['log_id']},
      );
      if (res.isEmpty) return Response.notFound('Log not found');
      final log = res.first.toColumnMap();

      if (log['status'] == 'returned') {
        return Response.badRequest(body: 'Already returned');
      }

      // Add Stock Back (To Local)
      await session.execute(
        Sql.named(
          'UPDATE products SET stock_qty = stock_qty + @qty, local_qty = COALESCE(local_qty, 0) + @qty WHERE id = @pid',
        ),
        parameters: {'pid': log['product_id'], 'qty': log['qty']},
      );

      // Update Log
      await session.execute(
        Sql.named("UPDATE product_logs SET status = 'returned' WHERE id = @id"),
        parameters: {'id': p['log_id']},
      );

      return Response.ok(jsonEncode({'success': true}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// C. Get Logs
Future<Response> getServiceLogs(Request request) async {
  final res = await pool.execute(
    Sql.named(
      "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC",
    ),
  );
  final list = res.map((r) => r.toColumnMap()).toList();
  for (var item in list) {
    item['created_at'] = item['created_at'].toString();
  }
  return Response.ok(jsonEncode(list));
}

/// ===============================
/// MAIN
/// ===============================
void main() async {
  pool = Pool.withEndpoints(
    [
      Endpoint(
        host: Platform.environment['DB_HOST'] ?? 'localhost',
        port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        database: Platform.environment['DB_NAME']!,
        username: Platform.environment['DB_USER']!,
        password: Platform.environment['DB_PASS']!,
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: SslMode.require,    ),
  );

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler((Request request) {
        final path = request.url.path;
        if (path == 'products' && request.method == 'GET') {
          return fetchProducts(request);
        }
        if (path == 'products' && request.method == 'POST') {
          return insertProducts(request);
        }
        if (path == 'products/add' && request.method == 'POST') {
          return addSingleProduct(request);
        }
        if (path == 'products/add-stock' && request.method == 'POST') {
          return addStockMixed(request);
        }
        if (path == 'products/recalculate-prices' && request.method == 'PUT') {
          return recalculateAirSea(request);
        }
        if (path == 'products/bulk-update-stock' && request.method == 'PUT') {
          return bulkUpdateStock(request);
        }
        if (path.startsWith('products/') && request.method == 'PUT') {
          return updateProduct(request);
        }
        if (path.startsWith('products/') && request.method == 'DELETE') {
          return deleteProduct(request);
        }

        // NEW ENDPOINTS
        if (path == 'service/add' && request.method == 'POST') {
          return addToService(request);
        }
        if (path == 'service/return' && request.method == 'POST') {
          return returnFromService(request);
        }
        if (path == 'service/list' && request.method == 'GET') {
          return getServiceLogs(request);
        }

        return Response.notFound('Route not found');
      });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on port $port');
}
