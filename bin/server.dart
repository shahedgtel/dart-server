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
              shipmenttax, shipmentno, currency, stock_qty, avg_purchase_price, 
              sea_stock_qty, air_stock_qty, local_qty
            ) VALUES (
              @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale, 
              @tax, @sNo, @curr, @stock, @avg, @sStock, @aStock, 0
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
          shipmenttax, shipmentno, currency, stock_qty, avg_purchase_price, 
          sea_stock_qty, air_stock_qty, local_qty
        ) VALUES (
          @name, @cat, @brand, @model, @weight, @yuan, @sea, @air, @agent, @wholesale, 
          @tax, @sNo, @curr, @stock, @avg, @sStock, @aStock, 0
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
/// 4. ADD STOCK (MIXED) - FIXED: AIR=700, SEA=DB Column
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
      // 1. Fetch current data
      final res = await session.execute(
        Sql.named(
          'SELECT stock_qty, avg_purchase_price, yuan, currency, weight, shipmenttax FROM products WHERE id = @id',
        ),
        parameters: {'id': id},
      );

      if (res.isEmpty) return Response.notFound('Product not found');
      final row = res.first.toColumnMap();

      // Current Data
      final double oldQty = safeNum(row['stock_qty'])?.toDouble() ?? 0.0;
      final double oldAvg =
          safeNum(row['avg_purchase_price'])?.toDouble() ?? 0.0;

      // Cost Calculation Factors
      final double yuan = safeNum(row['yuan'])?.toDouble() ?? 0.0;
      final double curr = safeNum(row['currency'])?.toDouble() ?? 0.0;
      final double weight = safeNum(row['weight'])?.toDouble() ?? 0.0;
      final double tax = safeNum(row['shipmenttax'])?.toDouble() ?? 0.0;

      // 2. Calculate New Batch Value

      // SEA Cost = (Yuan * Currency) + (Weight * shipmenttax)
      final double seaUnitCost = (yuan * curr) + (weight * tax);

      // AIR Cost = (Yuan * Currency) + (Weight * 700) <-- FIXED: 700 for Air
      final double airUnitCost = (yuan * curr) + (weight * 700);

      // Total Incoming Value = Sea Total + Air Total + Local Total
      final double totalValueIncoming =
          (incSea * seaUnitCost) +
          (incAir * airUnitCost) +
          (incLocal * localPrice);

      // 3. Weighted Average Math
      final double totalValueOld = oldQty * oldAvg;
      final double newTotalQty = oldQty + totalIncoming;

      final double newAvg = newTotalQty > 0
          ? (totalValueOld + totalValueIncoming) / newTotalQty
          : 0.0;

      // 4. Update Database
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
    print("AddMixStock Server Error: $e");
    return Response.internalServerError(body: "Server Error: ${e.toString()}");
  }
}

/// ===============================
/// 5. BULK CURRENCY UPDATE (PROTECT LOCAL + AIR=700)
/// ===============================
Future<Response> recalculateAirSea(Request request) async {
  try {
    final data = jsonDecode(await request.readAsString());
    final double newCurr = safeNum(data['currency'])?.toDouble() ?? 0.0;

    if (newCurr <= 0) {
      return Response.badRequest(body: 'Valid currency required');
    }

    // Logic:
    // 1. Calculate 'Current Total Value' based on stock * avg.
    // 2. Calculate 'Old Import Value'. NOTE: Air uses 700, Sea uses shipmenttax.
    // 3. Subtract Import from Total to isolate 'Local Value' (which must not change).
    // 4. Calculate 'New Import Value' using NEW Currency.
    // 5. Add 'Local Value' + 'New Import Value' to get 'New Total Value'.
    // 6. Divide by Total Qty to get new Avg.

    await pool.execute(
      Sql.named('''
        UPDATE products SET 
          -- Update Currency Column first so we can reference @newC easily
          currency = @newC,

          -- Recalculate AVG PRICE
          avg_purchase_price = CASE 
            WHEN stock_qty > 0 THEN
              (
                (
                  -- Current Total Value - Old Import Value (Separated by Sea/Air)
                  (stock_qty * avg_purchase_price) - 
                  (
                    (sea_stock_qty * ((yuan * currency) + (weight * shipmenttax))) + 
                    (air_stock_qty * ((yuan * currency) + (weight * 700))) -- Air=700
                  )
                ) 
                + 
                -- Add New Import Value
                (
                  (sea_stock_qty * ((yuan * @newC) + (weight * shipmenttax))) + 
                  (air_stock_qty * ((yuan * @newC) + (weight * 700))) -- Air=700
                )
              ) / stock_qty
            ELSE 0 
          END,

          -- Update Display Columns
          sea = (yuan * @newC) + (weight * shipmenttax), -- Sea uses shipmenttax
          air = (yuan * @newC) + (weight * 700) -- Air uses 700

        WHERE yuan > 0 -- Only update items that have Yuan/Import data
      '''),
      parameters: {'newC': newCurr},
    );
    return Response.ok(jsonEncode({'success': true}));
  } catch (e) {
    return Response.internalServerError(body: e.toString());
  }
}

/// ===============================
/// 6. POS CHECKOUT (WATERFALL DEDUCTION)
/// ===============================
Future<Response> bulkUpdateStock(Request request) async {
  try {
    final Map<String, dynamic> body = jsonDecode(await request.readAsString());
    final List updates = body['updates'] ?? [];

    await pool.runTx((session) async {
      for (final item in updates) {
        int qty = safeNum(item['qty'])?.toInt() ?? 0;
        int id = safeNum(item['id'])?.toInt() ?? 0;

        // Logic: Deduct Local -> Air -> Sea
        await session.execute(
          Sql.named('''
            UPDATE products SET 
              stock_qty = GREATEST(0, stock_qty - @qty),
              
              -- 1. Deduct Local First
              local_qty = CASE 
                WHEN COALESCE(local_qty, 0) >= @qty THEN local_qty - @qty 
                ELSE 0 
              END,

              -- 2. Deduct Air Second (if Local ran out)
              air_stock_qty = CASE 
                WHEN COALESCE(local_qty, 0) >= @qty THEN air_stock_qty -- Local covered it
                WHEN (COALESCE(local_qty, 0) + air_stock_qty) >= @qty THEN air_stock_qty - (@qty - COALESCE(local_qty, 0))
                ELSE 0 -- Local + Air drained
              END,

              -- 3. Deduct Sea Last (if Local + Air ran out)
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

    // Get Total
    final totalRes = await pool.execute(
      Sql.named("SELECT COUNT(*)::int FROM products $where"),
      parameters: countParams,
    );
    final int total = totalRes.first.toColumnMap()['count'] ?? 0;

    // Get Data
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
