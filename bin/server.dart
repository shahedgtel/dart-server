import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

/// ===============================
/// CORS
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
/// OPEN CONNECTION (PER REQUEST)
/// ===============================
Future<PostgreSQLConnection> openConnection() async {
  final conn = PostgreSQLConnection(
    Platform.environment['DB_HOST']!,
    int.parse(Platform.environment['DB_PORT'] ?? '6543'),
    Platform.environment['DB_NAME']!,
    username: Platform.environment['DB_USER'],
    password: Platform.environment['DB_PASS'],
    useSSL: true,
  );

  await conn.open();
  return conn;
}

/// ===============================
/// SAFE PARSERS
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
/// BULK INSERT
/// ===============================
Future<Response> insertProducts(Request request) async {
  final conn = await openConnection();
  try {
    final List products = jsonDecode(await request.readAsString());

    await conn.transaction((ctx) async {
      for (final p in products) {
        await ctx.query(
          '''
          INSERT INTO products
          (
            name, category, brand, model, weight,
            yuan, sea, air, agent, wholesale,
            shipmentTax, shipmentNo, currency, stock_qty
          )
          VALUES
          (
            @name,@category,@brand,@model,@weight,
            @yuan,@sea,@air,@agent,@wholesale,
            @shipmentTax,@shipmentNo,@currency,@stock_qty
          )
          ''',
          substitutionValues: {
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
  } finally {
    await conn.close();
  }
}

/// ===============================
/// UPDATE ALL CURRENCY
/// ===============================
Future<Response> updateAllCurrency(Request request) async {
  final conn = await openConnection();
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);

    if (currency == null) {
      return Response.badRequest(body: 'currency required');
    }

    final updated = await conn.execute(
      'UPDATE products SET currency=@currency',
      substitutionValues: {'currency': currency},
    );

    return Response.ok(jsonEncode({'rows': updated}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// 🔥 RECALCULATE AIR & SEA
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  final conn = await openConnection();
  try {
    final data = jsonDecode(await request.readAsString());
    final currency = safeNum(data['currency']);

    if (currency == null) {
      return Response.badRequest(body: 'currency required');
    }

    final updated = await conn.execute(
      '''
      UPDATE products
      SET
        currency = @currency,
        air = (yuan * @currency) + (weight * 700),
        sea = (yuan * @currency) + (weight * shipmentTax)
      ''',
      substitutionValues: {'currency': currency},
    );

    return Response.ok(jsonEncode({
      'success': true,
      'rows_affected': updated,
    }));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
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

    final r = await conn.query(
      '''
      INSERT INTO products
      (
        name, category, brand, model, weight,
        yuan, sea, air, agent, wholesale,
        shipmentTax, shipmentNo, currency, stock_qty
      )
      VALUES
      (
        @name,@category,@brand,@model,@weight,
        @yuan,@sea,@air,@agent,@wholesale,
        @shipmentTax,@shipmentNo,@currency,@stock_qty
      )
      RETURNING id
      ''',
      substitutionValues: {
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
      useSimpleQueryProtocol: true,
    );

    return Response.ok(jsonEncode({'id': r.first.first}));
  } finally {
    await conn.close();
  }
}

/// ===============================
/// UPDATE PRODUCT
/// ===============================
Future<Response> updateProduct(Request request) async {
  final conn = await openConnection();
  try {
    final id = int.parse(request.url.pathSegments.last);
    final p = jsonDecode(await request.readAsString());

    await conn.execute(
      '''
      UPDATE products SET
        name=@name, category=@category, brand=@brand, model=@model,
        weight=@weight, yuan=@yuan, sea=@sea, air=@air,
        agent=@agent, wholesale=@wholesale,
        shipmentTax=@shipmentTax, shipmentNo=@shipmentNo,
        currency=@currency, stock_qty=@stock_qty
      WHERE id=@id
      ''',
      substitutionValues: {
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

    return Response.ok('updated');
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
      'DELETE FROM products WHERE id=@id',
      substitutionValues: {'id': id},
    );
    return Response.ok('deleted');
  } finally {
    await conn.close();
  }
}

/// ===============================
/// FETCH PRODUCTS (🔥 FIXED)
/// ===============================
Future<Response> fetchProducts(Request request) async {
  final conn = await openConnection();
  try {
    final r = await conn.query('SELECT * FROM products ORDER BY id', useSimpleQueryProtocol: true);

    final list = r.map((e) => {
          'id': e[0],
          'name': e[1],
          'category': e[2],
          'brand': e[3],
          'model': e[4],
          'weight': e[5],
          'yuan': e[6],
          'sea': e[7],
          'air': e[8],
          'agent': e[9],
          'wholesale': e[10],
          'shipmentTax': e[11],
          'shipmentNo': e[12],
          'currency': e[13],
          'stock_qty': e[14],
        }).toList();

    return Response.ok(
      jsonEncode(list),
      headers: {'Content-Type': 'application/json'},
    );
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
    if (path == 'products/recalculate-prices' &&
        request.method == 'PUT') {
      return recalculateAirSea(request);
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
