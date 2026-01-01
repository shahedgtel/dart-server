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
              shipmenttax, shipmentno, currency, stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty
            ) VALUES (
              @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale, 
              @tax, @sNo, @curr, @stock, @avg, @sStock, @aStock
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
          shipmenttax, shipmentno, currency, stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty
        ) VALUES (
          @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale, 
          @tax, @sNo, @curr, @stock, @avg, @sStock, @aStock
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
          sea=@sea, air=@air, agent=@agent, wholesale=@wholesale, shipmenttax=@tax, 
          shipmentno=@sNo, currency=@curr, stock_qty=@stock, avg_purchase_price=@avg, 
          sea_stock_qty=@sStock, air_stock_qty=@aStock
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
        'sNo': safeNum(p['shipmentno']),
        'curr': safeNum(p['currency']),
        'stock': safeNum(p['stock_qty']),
        'avg': safeNum(p['avg_purchase_price']),
        'sStock': safeNum(p['sea_stock_qty']),
        'aStock': safeNum(p['air_stock_qty']),
      },
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 4. ADD STOCK (MIXED)
/// ===============================
Future<Response> addStockMixed(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final int id = p['id'];
    final int incSea = (p['sea_qty'] ?? 0).toInt();
    final int incAir = (p['air_qty'] ?? 0).toInt();
    final int incLocal = (p['local_qty'] ?? 0).toInt();
    final double localPrice = (p['local_price'] ?? 0).toDouble();

    return await pool.runTx((session) async {
      final res = await session.execute(
        Sql.named(
          'SELECT stock_qty, avg_purchase_price, sea, air FROM products WHERE id = @id',
        ),
        parameters: {'id': id},
      );
      if (res.isEmpty) return Response.notFound('Not found');
      final row = res.first.toColumnMap();

      double oldQty = (row['stock_qty'] ?? 0).toDouble();
      double oldAvg = (row['avg_purchase_price'] ?? 0).toDouble();
      double seaPrice = (row['sea'] ?? 0).toDouble();
      double airPrice = (row['air'] ?? 0).toDouble();

      double newBatchValue =
          (incSea * seaPrice) + (incAir * airPrice) + (incLocal * localPrice);
      double totalNewQty = oldQty + incSea + incAir + incLocal;
      double newAvg = totalNewQty > 0
          ? ((oldQty * oldAvg) + newBatchValue) / totalNewQty
          : 0;

      await session.execute(
        Sql.named('''
          UPDATE products SET 
            stock_qty = stock_qty + @incTotal,
            sea_stock_qty = sea_stock_qty + @incSea + @incLocal,
            air_stock_qty = air_stock_qty + @incAir,
            avg_purchase_price = @newAvg
          WHERE id = @id
        '''),
        parameters: {
          'id': id,
          'incTotal': incSea + incAir + incLocal,
          'incSea': incSea,
          'incLocal': incLocal,
          'incAir': incAir,
          'newAvg': newAvg,
        },
      );
      return Response.ok(jsonEncode({'success': true, 'new_avg': newAvg}));
    });
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 5. POS CHECKOUT
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];
    await pool.runTx((session) async {
      for (final item in updates) {
        await session.execute(
          Sql.named('''
            UPDATE products SET 
              stock_qty = stock_qty - @qty,
              sea_stock_qty = CASE WHEN sea_stock_qty >= @qty THEN sea_stock_qty - @qty ELSE 0 END,
              air_stock_qty = CASE WHEN sea_stock_qty < @qty 
                                   THEN air_stock_qty - (@qty - sea_stock_qty) 
                                   ELSE air_stock_qty END
            WHERE id = @id
          '''),
          parameters: {'id': item['id'], 'qty': item['qty']},
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. RECALCULATE (Handles Superfluous variable logic)
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final curr = safeNum(data['currency']);
    if (curr == null) return Response.badRequest(body: 'currency required');

    await pool.execute(
      Sql.named('''
        UPDATE products SET 
          currency=@c, 
          air=(yuan*@c)+(weight*700), 
          sea=(yuan*@c)+(weight*shipmenttax),
          avg_purchase_price = CASE WHEN yuan > 0 THEN (yuan*@c)+(weight*shipmenttax) ELSE avg_purchase_price END
      '''),
      parameters: {'c': curr},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 7. FETCH PRODUCTS (FIXED FOR SUPERFLUOUS VARIABLES)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final q = request.url.queryParameters;
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final search = q['search']?.trim() ?? '';
    final offset = (page - 1) * limit;

    // 1. Logic for Search Parameter
    String where = "";
    final countParams = <String, dynamic>{};
    final selectParams = <String, dynamic>{'l': limit, 'o': offset};

    if (search.isNotEmpty) {
      where = "WHERE model ILIKE @s OR name ILIKE @s OR brand ILIKE @s";
      countParams['s'] = '%$search%';
      selectParams['s'] = '%$search%';
    }

    // 2. GET TOTAL COUNT (Using countParams map)
    final totalRes = await pool.execute(
      Sql.named("SELECT COUNT(*)::int FROM products $where"),
      parameters: countParams,
    );
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    // 3. GET PRODUCTS (Using selectParams map)
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
    print("FATAL FETCH ERROR: $e");
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

void main() async {
  pool = Pool.withEndpoints([
    Endpoint(
      host: Platform.environment['DB_HOST'] ?? 'localhost',
      port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
      database: Platform.environment['DB_NAME']!,
      username: Platform.environment['DB_USER']!,
      password: Platform.environment['DB_PASS']!,
    ),
  ], settings: PoolSettings(maxConnectionCount: 10, sslMode: SslMode.disable));

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
        return Response.notFound('Route not found');
      });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on port $port');
}
