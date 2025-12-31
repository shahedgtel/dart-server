import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

/// ===============================
/// GLOBAL CONNECTION POOL
/// ===============================
late final Pool pool;

/// ===============================
/// CORS Middleware
/// ===============================
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
/// Safe Parsers
/// ===============================
num? safeNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return num.tryParse(s);
}

String? safeStr(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return s;
}

/// ===============================
/// 1. BULK INSERT PRODUCTS (Handles 18 Fields)
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    final List products = jsonDecode(await request.readAsString());

    await pool.runTx((session) async {
      for (final p in products) {
        await session.execute(
          Sql.named('''
            INSERT INTO products
            (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, 
             shipmentTax, shipmentNo, currency, stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty)
            VALUES
            (@name,@category,@brand,@model,@weight,@yuan,@sea,@air,@agent,@wholesale,
             @shipmentTax,@shipmentNo,@currency,@stock_qty,@avg_price,@sea_stock,@air_stock)
          '''),
          parameters: {
            'name': safeStr(p['name']),
            'category': safeStr(p['category']),
            'brand': safeStr(p['brand']),
            'model': safeStr(p['model']),
            'weight': safeNum(p['weight']),
            'yuan': safeNum(p['yuan']),
            'sea': safeNum(p['sea']),
            'air': safeNum(p['air']),
            'agent': safeNum(p['agent']),
            'wholesale': safeNum(p['wholesale']),
            'shipmentTax': safeNum(p['shipmentTax']),
            'shipmentNo': safeNum(p['shipmentNo']),
            'currency': safeNum(p['currency']),
            'stock_qty': safeNum(p['stock_qty']) ?? 0,
            'avg_price': safeNum(p['avg_purchase_price']) ?? 0,
            'sea_stock': safeNum(p['sea_stock_qty']) ?? 0,
            'air_stock': safeNum(p['air_stock_qty']) ?? 0,
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
/// 2. ADD SINGLE PRODUCT (Handles 18 Fields)
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final result = await pool.execute(
      Sql.named('''
        INSERT INTO products
        (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, 
         shipmentTax, shipmentNo, currency, stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty)
        VALUES
        (@name,@category,@brand,@model,@weight,@yuan,@sea,@air,@agent,@wholesale,
         @shipmentTax,@shipmentNo,@currency,@stock_qty,@avg_price,@sea_stock,@air_stock)
        RETURNING id
      '''),
      parameters: {
        'name': safeStr(p['name']),
        'category': safeStr(p['category']),
        'brand': safeStr(p['brand']),
        'model': safeStr(p['model']),
        'weight': safeNum(p['weight']),
        'yuan': safeNum(p['yuan']),
        'sea': safeNum(p['sea']),
        'air': safeNum(p['air']),
        'agent': safeNum(p['agent']),
        'wholesale': safeNum(p['wholesale']),
        'shipmentTax': safeNum(p['shipmentTax']),
        'shipmentNo': safeNum(p['shipmentNo']),
        'currency': safeNum(p['currency']),
        'stock_qty': safeNum(p['stock_qty']) ?? 0,
        'avg_price': safeNum(p['avg_purchase_price']) ?? 0,
        'sea_stock': safeNum(p['sea_stock_qty']) ?? 0,
        'air_stock': safeNum(p['air_stock_qty']) ?? 0,
      },
    );
    return Response.ok(jsonEncode({'id': result.first.toColumnMap()['id']}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 3. UPDATE PRODUCT (Handles 18 Fields)
/// ===============================
Future<Response> updateProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());
    await pool.execute(
      Sql.named('''
        UPDATE products SET
          name=@name, category=@category, brand=@brand, model=@model, weight=@weight, yuan=@yuan, 
          sea=@sea, air=@air, agent=@agent, wholesale=@wholesale, shipmentTax=@shipmentTax, 
          shipmentNo=@shipmentNo, currency=@currency, stock_qty=@stock_qty, 
          avg_purchase_price=@avg_price, sea_stock_qty=@sea_stock, air_stock_qty=@air_stock
        WHERE id=@id
      '''),
      parameters: {
        'id': id,
        'name': safeStr(p['name']),
        'category': safeStr(p['category']),
        'brand': safeStr(p['brand']),
        'model': safeStr(p['model']),
        'weight': safeNum(p['weight']),
        'yuan': safeNum(p['yuan']),
        'sea': safeNum(p['sea']),
        'air': safeNum(p['air']),
        'agent': safeNum(p['agent']),
        'wholesale': safeNum(p['wholesale']),
        'shipmentTax': safeNum(p['shipmentTax']),
        'shipmentNo': safeNum(p['shipmentNo']),
        'currency': safeNum(p['currency']),
        'stock_qty': safeNum(p['stock_qty']),
        'avg_price': safeNum(p['avg_purchase_price']),
        'sea_stock': safeNum(p['sea_stock_qty']),
        'air_stock': safeNum(p['air_stock_qty']),
      },
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 4. ADD STOCK (MIXED SHIPMENT & WAC CALCULATION)
/// ===============================
Future<Response> addStockMixed(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final int id = p['id'];
    final int incSea = (p['sea_qty'] ?? 0).toInt();
    final int incAir = (p['air_qty'] ?? 0).toInt();
    final int totalIncoming = incSea + incAir;

    if (totalIncoming <= 0) return Response.badRequest(body: 'Qty must be > 0');

    return await pool.runTx((session) async {
      final res = await session.execute(
        Sql.named(
          'SELECT stock_qty, avg_purchase_price, sea, air FROM products WHERE id = @id',
        ),
        parameters: {'id': id},
      );

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      final double oldQty = (row['stock_qty'] ?? 0).toDouble();
      final double oldAvg = (row['avg_purchase_price'] ?? 0).toDouble();

      // Use the 'sea' and 'air' columns which store current landing cost
      final double seaRef = (row['sea'] ?? 0).toDouble();
      final double airRef = (row['air'] ?? 0).toDouble();

      // Calculate total value of new shipment
      double newBatchValue = (incSea * seaRef) + (incAir * airRef);

      // New Weighted Average: ((Old Total Value) + (New Batch Value)) / (New Total Qty)
      double oldTotalValue = oldQty * oldAvg;
      double newTotalQty = oldQty + totalIncoming;
      double newAvg = (oldTotalValue + newBatchValue) / newTotalQty;

      await session.execute(
        Sql.named('''
          UPDATE products SET 
            stock_qty = stock_qty + @incTotal,
            sea_stock_qty = sea_stock_qty + @incSea,
            air_stock_qty = air_stock_qty + @incAir,
            avg_purchase_price = @newAvg
          WHERE id = @id
        '''),
        parameters: {
          'id': id,
          'incTotal': totalIncoming,
          'incSea': incSea,
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
/// 5. BULK UPDATE STOCK (POS CHECKOUT - FIFO Deduct)
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    await pool.runTx((session) async {
      for (final item in updates) {
        final int id = item['id'];
        final int sellQty = item['qty'];

        // Subtract from Total Stock
        // Logic: Deduct from Sea stock first, then the rest from Air stock if sea is empty
        await session.execute(
          Sql.named('''
            UPDATE products SET 
              stock_qty = stock_qty - @qty,
              air_stock_qty = CASE 
                  WHEN sea_stock_qty < @qty THEN air_stock_qty - (@qty - sea_stock_qty)
                  ELSE air_stock_qty 
              END,
              sea_stock_qty = CASE 
                  WHEN sea_stock_qty >= @qty THEN sea_stock_qty - @qty 
                  ELSE 0 
              END
            WHERE id = @id
          '''),
          parameters: {'id': id, 'qty': sellQty},
        );
      }
    });
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. RECALCULATE AIR & SEA (Reference Landing Costs)
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);
    if (currency == null) return Response.badRequest(body: 'currency required');

    await pool.execute(
      Sql.named('''
      UPDATE products SET
        currency=@currency,
        air=(yuan*@currency)+(weight*700),
        sea=(yuan*@currency)+(weight*shipmentTax)
    '''),
      parameters: {'currency': currency},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 7. FETCH PRODUCTS (Handles all 18 fields)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final q = request.url.queryParameters;
    final page = int.tryParse(q['page'] ?? '1') ?? 1;
    final limit = int.tryParse(q['limit'] ?? '20') ?? 20;
    final offset = (page - 1) * limit;
    final search = q['search']?.trim() ?? '';

    String where = search.isNotEmpty
        ? 'WHERE model ILIKE @s OR name ILIKE @s OR brand ILIKE @s'
        : '';

    final countRes = await pool.execute(
      Sql.named('SELECT COUNT(*) FROM products $where'),
      parameters: {'s': '%$search%'},
    );

    final results = await pool.execute(
      Sql.named(
        'SELECT * FROM products $where ORDER BY id DESC LIMIT @l OFFSET @o',
      ),
      parameters: {'s': '%$search%', 'l': limit, 'o': offset},
    );

    return Response.ok(
      jsonEncode({
        'products': results.map((r) => r.toColumnMap()).toList(),
        'total': countRes.first.toColumnMap()['count'],
      }),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 8. DELETE PRODUCT
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
/// MAIN SERVER
/// ===============================
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
