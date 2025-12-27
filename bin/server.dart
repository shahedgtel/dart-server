import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

/// ===============================
/// GLOBAL CONNECTION POOL
/// ===============================
// We use a late final pool so it's initialized once and shared across all handlers.
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
/// BULK INSERT PRODUCTS
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    final List products = jsonDecode(await request.readAsString());

    // Using pool.runTx ensures all inserts happen in one transaction
    await pool.runTx((session) async {
      for (final p in products) {
        await session.execute(
          Sql.named('''
            INSERT INTO products
            (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
            VALUES
            (@name,@category,@brand,@model,@weight,@yuan,@sea,@air,@agent,@wholesale,@shipmentTax,@shipmentNo,@currency,@stock_qty)
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
            'stock_qty': safeNum(p['stock_qty']),
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
/// ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  try {
    final p = jsonDecode(await request.readAsString());
    final sql = Sql.named('''
      INSERT INTO products
      (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
      VALUES
      (@name,@category,@brand,@model,@weight,@yuan,@sea,@air,@agent,@wholesale,@shipmentTax,@shipmentNo,@currency,@stock_qty)
      RETURNING id
    ''');

    final result = await pool.execute(
      sql,
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
        'stock_qty': safeNum(p['stock_qty']),
      },
    );

    return Response.ok(jsonEncode({'id': result.first.toColumnMap()['id']}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// UPDATE SINGLE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());
    final sql = Sql.named('''
      UPDATE products SET
        name=@name, category=@category, brand=@brand, model=@model,
        weight=@weight, yuan=@yuan, sea=@sea, air=@air,
        agent=@agent, wholesale=@wholesale,
        shipmentTax=@shipmentTax, shipmentNo=@shipmentNo,
        currency=@currency, stock_qty=@stock_qty
      WHERE id=@id
    ''');

    await pool.execute(
      sql,
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
      },
    );

    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// DELETE PRODUCT
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
/// BULK UPDATE CURRENCY
/// ===============================
Future<Response> updateAllCurrency(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);
    if (currency == null) return Response.badRequest(body: 'currency required');

    await pool.execute(
      Sql.named('UPDATE products SET currency=@currency'),
      parameters: {'currency': currency},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

// Add this to your main server file
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    await pool.runTx((session) async {
      for (final item in updates) {
        // We use @stock_qty to match your other methods
        await session.execute(
          Sql.named('UPDATE products SET stock_qty = stock_qty - @stock_qty WHERE id = @id'),
          parameters: {
            'id': item['id'], 
            'stock_qty': item['qty'] // 'qty' from Flutter mapped to @stock_qty
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
/// RECALCULATE AIR & SEA
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
/// FETCH PRODUCTS WITH PAGINATION + SEARCH
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    final queryParams = request.url.queryParameters;
    final page = int.tryParse(queryParams['page'] ?? '1') ?? 1;
    final limit = int.tryParse(queryParams['limit'] ?? '20') ?? 20;
    final offset = (page - 1) * limit;
    final search = queryParams['search']?.trim() ?? '';
    final brand = queryParams['brand']?.trim() ?? '';

    // Build WHERE clause
    final where = <String>[];
    final params = <String, dynamic>{};

    if (search.isNotEmpty) {
      where.add('model ILIKE @search');
      params['search'] = '%$search%';
    }
    if (brand.isNotEmpty) {
      where.add('brand = @brand');
      params['brand'] = brand;
    }

    final whereSQL = where.isNotEmpty ? 'WHERE ${where.join(' AND ')}' : '';

    // Count total
    final countSql = Sql.named(
      'SELECT COUNT(*) AS total FROM products $whereSQL',
    );
    final countResult = await pool.execute(countSql, parameters: params);
    final total = countResult.first.toColumnMap()['total'] as int;

    // Paginated select
    final sql = Sql.named('''
      SELECT * FROM products
      $whereSQL
      ORDER BY id
      LIMIT @limit OFFSET @offset
    ''');

    final results = await pool.execute(
      sql,
      parameters: {...params, 'limit': limit, 'offset': offset},
    );

    final list = results.map((row) => row.toColumnMap()).toList();

    return Response.ok(
      jsonEncode({'products': list, 'total': total}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    // If we catch the "prepared statement already exists" error here,
    // it's usually because we aren't using a pool. Using pool.execute handles this.
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// SERVER
/// ===============================
void main() async {
  // Initialize the Pool with your environment variables
  // The pool manages connections automatically. No need to open/close manually.
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
      maxConnectionCount: 10, // Allows up to 10 concurrent DB connections
      sslMode: SslMode
          .disable, // Set according to your DB provider (e.g., SslMode.require for Neon/Render)
    ),
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
        if (path == 'products/currency' && request.method == 'PUT') {
          return updateAllCurrency(request);
        }
        if (path == 'products/recalculate-prices' && request.method == 'PUT') {
          return recalculateAirSea(request);
        }
        if (path.startsWith('products/') && request.method == 'PUT') {
          return updateProduct(request);
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
  print('✅ Connection Pool initialized');
}
