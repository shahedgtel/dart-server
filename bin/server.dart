import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

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
/// Open Connection (Postgres 3.5.9)
/// ===============================
Future<Connection> openConnection() async {
  final conn = await Connection.open(Endpoint(
    host: Platform.environment['DB_HOST']!,
    port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
    database: Platform.environment['DB_NAME']!,
    username: Platform.environment['DB_USER']!,
    password: Platform.environment['DB_PASS']!,
  ));
  return conn;
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
  final conn = await openConnection();
  try {
    final List products = jsonDecode(await request.readAsString());
    await conn.runTx((session) async {
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
  } finally {
    await conn.close();
  }
}

/// ===============================
/// ADD SINGLE PRODUCT
/// ===============================
Future<Response> addSingleProduct(Request request) async {
  final conn = await openConnection();
  try {
    final p = jsonDecode(await request.readAsString());
    final result = await conn.execute(
      Sql.named('''
        INSERT INTO products
        (name, category, brand, model, weight, yuan, sea, air, agent, wholesale, shipmentTax, shipmentNo, currency, stock_qty)
        VALUES
        (@name,@category,@brand,@model,@weight,@yuan,@sea,@air,@agent,@wholesale,@shipmentTax,@shipmentNo,@currency,@stock_qty)
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
        'stock_qty': safeNum(p['stock_qty']),
      },
    );
    return Response.ok(jsonEncode({'id': result.first.toColumnMap()['id']}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// UPDATE SINGLE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  final conn = await openConnection();
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());
    await conn.execute(
      Sql.named('''
        UPDATE products SET
          name=@name, category=@category, brand=@brand, model=@model,
          weight=@weight, yuan=@yuan, sea=@sea, air=@air,
          agent=@agent, wholesale=@wholesale,
          shipmentTax=@shipmentTax, shipmentNo=@shipmentNo,
          currency=@currency, stock_qty=@stock_qty
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
      },
    );
    return Response.ok(jsonEncode({'success': true}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// DELETE PRODUCT
/// ===============================
Future<Response> deleteProduct(Request request) async {
  final conn = await openConnection();
  try {
    final id = int.parse(request.url.pathSegments.last);
    await conn.execute(
      Sql.named('DELETE FROM products WHERE id=@id'),
      parameters: {'id': id},
    );
    return Response.ok(jsonEncode({'success': true}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// BULK UPDATE CURRENCY
/// ===============================
Future<Response> updateAllCurrency(Request request) async {
  final conn = await openConnection();
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);
    if (currency == null) return Response.badRequest(body: 'currency required');

    await conn.execute(
      Sql.named('UPDATE products SET currency=@currency'),
      parameters: {'currency': currency},
    );
    return Response.ok(jsonEncode({'success': true}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// RECALCULATE AIR & SEA
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  final conn = await openConnection();
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);
    if (currency == null) return Response.badRequest(body: 'currency required');

    await conn.execute(
      Sql.named('''
        UPDATE products SET
          currency=@currency,
          air=(yuan*@currency)+(weight*700),
          sea=(yuan*@currency)+(weight*shipmentTax)
      '''),
      parameters: {'currency': currency},
    );

    return Response.ok(jsonEncode({'success': true}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// FETCH PRODUCTS WITH PAGINATION + SEARCH
/// ===============================
Future<Response> fetchProducts(Request request) async {
  final conn = await openConnection();
  try {
    final queryParams = request.url.queryParameters;
    final page = int.tryParse(queryParams['page'] ?? '1') ?? 1;
    final limit = int.tryParse(queryParams['limit'] ?? '20') ?? 20;
    final offset = (page - 1) * limit;
    final search = queryParams['search']?.trim() ?? '';

    String sql = 'SELECT * FROM products';
    final parameters = <dynamic>[];
    if (search.isNotEmpty) {
      sql += ' WHERE model ILIKE \$1';
      parameters.add('%$search%');
    }
    sql += ' ORDER BY id LIMIT \$${parameters.length + 1} OFFSET \$${parameters.length + 2}';
    parameters.add(limit);
    parameters.add(offset);

    final result = await conn.execute(sql, parameters: parameters);

    final list = result.map((r) => r.toColumnMap()).toList();

    return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
  } finally {
    await conn.close();
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
    if (path == 'products' && request.method == 'POST') return insertProducts(request);
    if (path == 'products/add' && request.method == 'POST') return addSingleProduct(request);
    if (path == 'products/currency' && request.method == 'PUT') return updateAllCurrency(request);
    if (path == 'products/recalculate-prices' && request.method == 'PUT') return recalculateAirSea(request);
    if (path.startsWith('products/') && request.method == 'PUT') return updateProduct(request);
    if (path.startsWith('products/') && request.method == 'DELETE') return deleteProduct(request);

    return Response.notFound('Route not found');
  });

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await shelf_io.serve(handler, '0.0.0.0', port);
  print('🚀 Server running on port $port');
}
