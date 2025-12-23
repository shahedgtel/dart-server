import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

/// ===============================
/// CORS MIDDLEWARE
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
            'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
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
/// DATABASE CONNECTION
/// ===============================
final connection = PostgreSQLConnection(
  Platform.environment['DB_HOST']!,
  int.parse(Platform.environment['DB_PORT'] ?? '6543'),
  Platform.environment['DB_NAME']!,
  username: Platform.environment['DB_USER'],
  password: Platform.environment['DB_PASS'],
  useSSL: true,
  timeoutInSeconds: 60,
);

/// ===============================
/// CONNECTION HELPER
/// ===============================
Future<void> ensureConnection() async {
  if (connection.isClosed) {
    await connection.open();
  }
}

/// ===============================
/// SAFE PARSERS
/// ===============================
num safeNum(dynamic v, {num defaultValue = 0}) {
  if (v == null) return defaultValue;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? defaultValue;
}

String safeStr(dynamic v, {String defaultValue = ''}) {
  if (v == null) return defaultValue;
  final s = v.toString().trim();
  if (s.isEmpty) return defaultValue;
  return s;
}

/// ===============================
/// BULK INSERT PRODUCTS (FIXED)
/// ===============================
Future<Response> insertProducts(Request request) async {
  try {
    await ensureConnection();
    final body = await request.readAsString();
    final List<dynamic> products = jsonDecode(body);

    if (products.isEmpty) return Response.badRequest(body: 'Empty product list');

    // Build bulk values string safely
    final values = products.map((p) {
      final name = "'${safeStr(p['name']).replaceAll("'", "''")}'";
      final category = "'${safeStr(p['category']).replaceAll("'", "''")}'";
      final brand = "'${safeStr(p['brand']).replaceAll("'", "''")}'";
      final model = "'${safeStr(p['model']).replaceAll("'", "''")}'";
      final weight = safeNum(p['weight']);
      final yuan = safeNum(p['yuan']);
      final sea = safeNum(p['sea']);
      final air = safeNum(p['air']);
      final agent = safeNum(p['agent']);
      final wholesale = safeNum(p['wholesale']);
      final shipmentTax = safeNum(p['shipmentTax']);
      final shipmentNo = safeNum(p['shipmentNo']);
      final currency = safeNum(p['currency']);
      final stockQty = safeNum(p['stock_qty']);

      return "($name, $category, $brand, $model, $weight, $yuan, $sea, $air, $agent, $wholesale, $shipmentTax, $shipmentNo, $currency, $stockQty)";
    }).join(', ');

    final sql = '''
      INSERT INTO products
      (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
      VALUES $values
    ''';

    await connection.query(sql);

    return Response.ok(
      jsonEncode({'success': true, 'inserted': products.length}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}

/// ===============================
/// UPDATE ALL PRODUCTS CURRENCY
/// ===============================
Future<Response> updateAllCurrency(Request request) async {
  try {
    await ensureConnection();
    final body = await request.readAsString();
    final num newCurrency = safeNum(jsonDecode(body)['currency']);

    final int updated = await connection.execute(
      'UPDATE products SET currency = @currency',
      substitutionValues: {'currency': newCurrency},
    );

    return Response.ok(
      jsonEncode({'success': true, 'message': 'Currency updated', 'rows_affected': updated}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}

/// ===============================
/// ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  try {
    await ensureConnection();
    final body = await request.readAsString();
    final Map<String, dynamic> product = jsonDecode(body);

    final result = await connection.query(
      '''
      INSERT INTO products
      (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
      VALUES
      (@name, @category, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale, @shipmentTax, @shipmentNo, @currency, @stock_qty)
      RETURNING id
      ''',
      substitutionValues: {
        'name': safeStr(product['name']),
        'category': safeStr(product['category']),
        'brand': safeStr(product['brand']),
        'model': safeStr(product['model']),
        'weight': safeNum(product['weight']),
        'yuan': safeNum(product['yuan']),
        'sea': safeNum(product['sea']),
        'air': safeNum(product['air']),
        'agent': safeNum(product['agent']),
        'wholesale': safeNum(product['wholesale']),
        'shipmentTax': safeNum(product['shipmentTax']),
        'shipmentNo': safeNum(product['shipmentNo']),
        'currency': safeNum(product['currency']),
        'stock_qty': safeNum(product['stock_qty']),
      },
    );

    return Response.ok(
      jsonEncode({'success': true, 'product_id': result.first.first}),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}

/// ===============================
/// UPDATE SINGLE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  try {
    await ensureConnection();
    final int id = int.parse(request.url.pathSegments.last);
    final body = await request.readAsString();
    final Map<String, dynamic> product = jsonDecode(body);

    final updated = await connection.execute(
      '''
      UPDATE products SET
        name=@name,
        category=@category,
        brand=@brand,
        model=@model,
        weight=@weight,
        yuan=@yuan,
        sea=@sea,
        air=@air,
        agent=@agent,
        wholesale=@wholesale,
        shipmentTax=@shipmentTax,
        shipmentNo=@shipmentNo,
        currency=@currency,
        stock_qty=@stock_qty
      WHERE id=@id
      ''',
      substitutionValues: {
        'id': id,
        'name': safeStr(product['name']),
        'category': safeStr(product['category']),
        'brand': safeStr(product['brand']),
        'model': safeStr(product['model']),
        'weight': safeNum(product['weight']),
        'yuan': safeNum(product['yuan']),
        'sea': safeNum(product['sea']),
        'air': safeNum(product['air']),
        'agent': safeNum(product['agent']),
        'wholesale': safeNum(product['wholesale']),
        'shipmentTax': safeNum(product['shipmentTax']),
        'shipmentNo': safeNum(product['shipmentNo']),
        'currency': safeNum(product['currency']),
        'stock_qty': safeNum(product['stock_qty']),
      },
    );

    if (updated == 0) return Response.notFound('Product not found');

    return Response.ok(jsonEncode({'success': true, 'updated_rows': updated}));
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  }
}

/// ===============================
/// DELETE SINGLE PRODUCT
/// ===============================
Future<Response> deleteProduct(Request request) async {
  try {
    await ensureConnection();
    final int id = int.parse(request.url.pathSegments.last);
    final deleted = await connection.execute(
      'DELETE FROM products WHERE id=@id',
      substitutionValues: {'id': id},
    );

    if (deleted == 0) return Response.notFound('Product not found');

    return Response.ok(jsonEncode({'success': true, 'deleted_rows': deleted}));
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  }
}

/// ===============================
/// FETCH ALL PRODUCTS
/// ===============================
Future<Response> fetchProducts(Request request) async {
  try {
    await ensureConnection();
    final results = await connection.query('SELECT * FROM products ORDER BY id ASC');

    final products = results.map((row) {
      return {
        'id': row[0],
        'name': row[1],
        'category': row[2],
        'brand': row[3],
        'model': row[4],
        'weight': row[5],
        'yuan': row[6],
        'sea': row[7],
        'air': row[8],
        'agent': row[9],
        'wholesale': row[10],
        'shipmentTax': row[11],
        'shipmentNo': row[12],
        'currency': row[13],
        'stock_qty': row[14],
      };
    }).toList();

    return Response.ok(jsonEncode(products), headers: {'Content-Type': 'application/json'});
  } catch (e) {
    return Response.internalServerError(
      body: jsonEncode({'success': false, 'error': e.toString()}),
    );
  }
}

/// ===============================
/// SERVER
/// ===============================
void main() async {
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler((Request request) {
    final path = request.url.path;

    if (path == 'products' && request.method == 'GET') return fetchProducts(request);
    if (path == 'products/currency' && request.method == 'PUT') return updateAllCurrency(request);
    if (path == 'products' && request.method == 'POST') return insertProducts(request);
    if (path == 'products/add' && request.method == 'POST') return addSingleProduct(request);
    if (path.startsWith('products/') && request.method == 'PUT') return updateProduct(request);
    if (path.startsWith('products/') && request.method == 'DELETE') return deleteProduct(request);

    return Response.notFound('Route not found');
  });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on http://${server.address.address}:${server.port}');
}
