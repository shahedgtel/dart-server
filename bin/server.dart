import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final Pool pool;

String dbVal(dynamic value) {
  if (value == null) return 'NULL';
  if (value is num) return value.toString();
  if (value is bool) return value ? 'TRUE' : 'FALSE';
  if (value is DateTime) return "'${value.toIso8601String()}'";

  final str = value.toString();
  return "'${str.replaceAll("'", "''")}'";
}

Future<dynamic> parseBody(Request request) async {
  try {
    final content = await request.readAsString();
    return content.isNotEmpty ? jsonDecode(content) : {};
  } catch (_) {
    throw const FormatException('Invalid JSON body');
  }
}

Object? dateSerializer(Object? item) {
  if (item is DateTime) return item.toIso8601String();
  return item;
}

int? safeInt(dynamic v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');

double? safeDouble(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

String? safeStr(dynamic v) => v?.toString().trim();

DateTime? safeDate(dynamic v) {
  if (v == null) return null;
  final text = v.toString();
  if (text.isEmpty || text == 'null' || text == '0') return null;
  return DateTime.tryParse(text);
}

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
        headers: {
          ...response.headers,
          'Access-Control-Allow-Origin': '*',
        },
      );
    };
  };
}

Response jsonOk(dynamic body) {
  return Response.ok(
    jsonEncode(body, toEncodable: dateSerializer),
    headers: {'Content-Type': 'application/json'},
  );
}

Response jsonBad(String message) {
  return Response.badRequest(
    body: jsonEncode({'error': message}),
    headers: {'Content-Type': 'application/json'},
  );
}

Response jsonError(Object e) {
  return Response.internalServerError(
    body: jsonEncode({'error': e.toString()}),
    headers: {'Content-Type': 'application/json'},
  );
}

class ApiController {
  Future<Response> fetchProducts(Request request) async {
    try {
      final q = request.url.queryParameters;

      final page = safeInt(q['page']) ?? 1;
      final limit = safeInt(q['limit']) ?? 20;
      final search = q['search']?.trim() ?? '';
      final brand = q['brand']?.trim() ?? '';
      final sortByLoss = q['sort'] == 'loss';
      final warehouseId = safeInt(q['warehouse_id']);
      final offset = (page - 1) * limit;

      var conditions = '1=1';

      if (search.isNotEmpty) {
        final safeSearch = dbVal('%$search%');
        conditions += '''
          AND (
            p.model ILIKE $safeSearch
            OR p.name ILIKE $safeSearch
            OR p.brand ILIKE $safeSearch
          )
        ''';
      }

      if (brand.isNotEmpty && brand != 'All') {
        conditions += ' AND p.brand = ${dbVal(brand)}';
      }

      if (warehouseId != null && warehouseId > 0) {
        conditions += '''
          AND EXISTS (
            SELECT 1
            FROM product_warehouse_stock x
            WHERE x.product_id = p.id
              AND x.warehouse_id = $warehouseId
              AND x.qty > 0
          )
        ''';
      }

      var orderBy = 'p.id DESC';

      if (sortByLoss) {
        orderBy = '''
          LEAST(
            COALESCE(p.agent, 0) - COALESCE(p.avg_purchase_price, 0),
            COALESCE(p.wholesale, 0) - COALESCE(p.avg_purchase_price, 0)
          ) ASC
        ''';
      }

      final results = await pool.runTx((session) async {
        final products = await session.execute('''
          SELECT
            p.*,
            COALESCE(
              json_agg(
                json_build_object(
                  'warehouse_id', w.id,
                  'warehouse_name', w.name,
                  'qty', pws.qty,
                  'location', pws.location
                )
                ORDER BY w.id ASC
              ) FILTER (WHERE pws.id IS NOT NULL),
              '[]'
            ) AS warehouse_stocks
          FROM products p
          LEFT JOIN product_warehouse_stock pws
            ON pws.product_id = p.id
            ${warehouseId != null && warehouseId > 0 ? 'AND pws.warehouse_id = $warehouseId' : ''}
          LEFT JOIN warehouses w
            ON w.id = pws.warehouse_id
          WHERE $conditions
          GROUP BY p.id
          ORDER BY $orderBy
          LIMIT $limit OFFSET $offset
        ''');

        final count = await session.execute(
          'SELECT COUNT(*)::int AS count FROM products p WHERE $conditions',
        );

        final totalValue = warehouseId != null && warehouseId > 0
            ? await session.execute('''
                SELECT SUM(
                  COALESCE(pws.qty, 0) * COALESCE(p.avg_purchase_price, 0)
                )::float8 AS total_val
                FROM products p
                JOIN product_warehouse_stock pws
                  ON pws.product_id = p.id
                WHERE $conditions
                  AND pws.warehouse_id = $warehouseId
              ''')
            : await session.execute('''
                SELECT SUM(
                  (COALESCE(p.sea_stock_qty, 0) * COALESCE(p.sea, 0)) +
                  (COALESCE(p.air_stock_qty, 0) * COALESCE(p.air, 0)) +
                  (COALESCE(p.local_qty, 0) * COALESCE(p.avg_purchase_price, 0))
                )::float8 AS total_val
                FROM products p
                WHERE $conditions
              ''');

        return [products, count, totalValue];
      });

      return jsonOk({
        'products': results[0].map((r) => r.toColumnMap()).toList(),
        'total': results[1].first.toColumnMap()['count'] ?? 0,
        'total_value': results[2].first.toColumnMap()['total_val'] ?? 0.0,
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> fetchShortList(Request request) async {
    try {
      final q = request.url.queryParameters;
      final search = q['search']?.trim() ?? '';

      var conditions = 'stock_qty <= alert_qty';

      if (search.isNotEmpty) {
        final safeSearch = dbVal('%$search%');
        conditions += '''
          AND (
            model ILIKE $safeSearch
            OR name ILIKE $safeSearch
            OR brand ILIKE $safeSearch
          )
        ''';
      }

      if (q['all'] == 'true') {
        final res = await pool.execute(
          'SELECT * FROM products WHERE $conditions ORDER BY stock_qty ASC',
        );

        return jsonOk({
          'products': res.map((r) => r.toColumnMap()).toList(),
        });
      }

      final page = safeInt(q['page']) ?? 1;
      final limit = safeInt(q['limit']) ?? 20;
      final offset = (page - 1) * limit;

      final results = await pool.runTx((session) async {
        final products = await session.execute(
          'SELECT * FROM products WHERE $conditions ORDER BY stock_qty ASC LIMIT $limit OFFSET $offset',
        );

        final count = await session.execute(
          'SELECT COUNT(*)::int AS count FROM products WHERE $conditions',
        );

        return [products, count];
      });

      return jsonOk({
        'products': results[0].map((r) => r.toColumnMap()).toList(),
        'total': results[1].first.toColumnMap()['count'] ?? 0,
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> fetchBrands(Request request) async {
    try {
      final res = await pool.execute('''
        SELECT DISTINCT brand
        FROM products
        WHERE brand IS NOT NULL AND TRIM(brand) <> ''
        ORDER BY brand ASC
      ''');

      return jsonOk({
        'brands': res
            .map((r) => r.toColumnMap()['brand']?.toString())
            .where((e) => e != null && e.isNotEmpty)
            .toList(),
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> fetchWarehouses(Request request) async {
    try {
      final res = await pool.execute(
        'SELECT * FROM warehouses ORDER BY id ASC',
      );

      return jsonOk({
        'warehouses': res.map((r) => r.toColumnMap()).toList(),
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> fetchWarehouseSummary(Request request) async {
    try {
      final res = await pool.execute('''
        SELECT
          w.id,
          w.name,
          w.is_active,
          COALESCE(SUM(pws.qty), 0)::int AS total_qty,
          COALESCE(SUM(pws.qty * COALESCE(p.avg_purchase_price, 0)), 0)::float8 AS total_value,
          COUNT(DISTINCT CASE WHEN pws.qty > 0 THEN p.id END)::int AS product_count
        FROM warehouses w
        LEFT JOIN product_warehouse_stock pws
          ON pws.warehouse_id = w.id
        LEFT JOIN products p
          ON p.id = pws.product_id
        GROUP BY w.id, w.name, w.is_active
        ORDER BY w.id ASC
      ''');

      return jsonOk({
        'warehouses': res.map((r) => r.toColumnMap()).toList(),
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> createWarehouse(Request request) async {
    try {
      final body = await parseBody(request);
      final name = safeStr(body['name']) ?? '';

      if (name.isEmpty) return jsonBad('Warehouse name is required');

      final res = await pool.execute(
        'INSERT INTO warehouses (name) VALUES (${dbVal(name)}) RETURNING id',
      );

      return jsonOk({
        'success': true,
        'id': res.first.toColumnMap()['id'],
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> updateWarehouse(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      final body = await parseBody(request);

      final name = safeStr(body['name']) ?? '';
      final isActive = body['is_active'] == false ? false : true;

      if (name.isEmpty) return jsonBad('Warehouse name is required');

      await pool.execute('''
        UPDATE warehouses
        SET
          name = ${dbVal(name)},
          is_active = ${dbVal(isActive)}
        WHERE id = $id
      ''');

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> insertProducts(Request request) async {
    try {
      final body = await parseBody(request);
      final List products = body is List ? body : body['items'] as List? ?? [];

      await pool.runTx((session) async {
        for (final raw in products) {
          final p = Map<String, dynamic>.from(raw as Map);
          final vals = _prepValues(p);

          final inserted = await session.execute('''
            INSERT INTO products (
              name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
              shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency,
              stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty, local_qty, alert_qty
            ) VALUES (
              ${vals['name']}, ${vals['category']}, ${vals['brand']}, ${vals['model']},
              ${vals['weight']}, ${vals['yuan']}, ${vals['sea']}, ${vals['air']},
              ${vals['agent']}, ${vals['wholesale']}, ${vals['shipmenttax']},
              ${vals['shipmenttaxair']}, ${vals['shipmentdate']}, ${vals['shipmentno']},
              ${vals['currency']}, ${vals['stock_qty']}, ${vals['avg_purchase_price']},
              ${vals['sea_stock_qty']}, ${vals['air_stock_qty']}, ${vals['local_qty']},
              ${vals['alert_qty']}
            )
            RETURNING id
          ''');

          final id = safeInt(inserted.first.toColumnMap()['id']) ?? 0;
          final stockQty = safeInt(p['stock_qty']) ?? 0;

          if (id > 0 && stockQty > 0) {
            final warehouseIdFromBody = safeInt(p['warehouse_id']);
            final warehouseId =
                warehouseIdFromBody != null && warehouseIdFromBody > 0
                    ? warehouseIdFromBody
                    : await _getDefaultWarehouseId(session);

            await _setWarehouseStock(
              session: session,
              productId: id,
              warehouseId: warehouseId,
              qty: stockQty,
              location: safeStr(p['warehouse_location']) ?? '',
            );
          }
        }
      });

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> addSingleProduct(Request request) async {
    try {
      final body = Map<String, dynamic>.from(await parseBody(request) as Map);
      final vals = _prepValues(body);

      final productId = await pool.runTx((session) async {
        final insert = await session.execute('''
          INSERT INTO products (
            name, category, brand, model, weight, yuan, sea, air, agent, wholesale,
            shipmenttax, shipmenttaxair, shipmentdate, shipmentno, currency,
            stock_qty, avg_purchase_price, sea_stock_qty, air_stock_qty, local_qty, alert_qty
          ) VALUES (
            ${vals['name']}, ${vals['category']}, ${vals['brand']}, ${vals['model']},
            ${vals['weight']}, ${vals['yuan']}, ${vals['sea']}, ${vals['air']},
            ${vals['agent']}, ${vals['wholesale']}, ${vals['shipmenttax']},
            ${vals['shipmenttaxair']}, ${vals['shipmentdate']}, ${vals['shipmentno']},
            ${vals['currency']}, ${vals['stock_qty']}, ${vals['avg_purchase_price']},
            ${vals['sea_stock_qty']}, ${vals['air_stock_qty']}, ${vals['local_qty']},
            ${vals['alert_qty']}
          )
          RETURNING id
        ''');

        final id = safeInt(insert.first.toColumnMap()['id']) ?? 0;
        final stockQty = safeInt(body['stock_qty']) ?? 0;

        if (stockQty > 0) {
          final warehouseIdFromBody = safeInt(body['warehouse_id']);
          final warehouseId =
              warehouseIdFromBody != null && warehouseIdFromBody > 0
                  ? warehouseIdFromBody
                  : await _getDefaultWarehouseId(session);

          await _setWarehouseStock(
            session: session,
            productId: id,
            warehouseId: warehouseId,
            qty: stockQty,
            location: safeStr(body['warehouse_location']) ?? '',
          );
        }

        return id;
      });

      return jsonOk({'id': productId});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> addStockMixed(Request request) async {
    try {
      final body = Map<String, dynamic>.from(await parseBody(request) as Map);
      return await _processAddStock(body);
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> bulkAddStockMixed(Request request) async {
    try {
      final body = await parseBody(request);
      final List items = body is List ? body : body['items'] as List? ?? [];
      var processed = 0;

      await pool.runTx((session) async {
        for (final raw in items) {
          await _processAddStockInSession(
            session,
            Map<String, dynamic>.from(raw as Map),
          );
          processed++;
        }
      });

      return jsonOk({'success': true, 'processed': processed});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> _processAddStock(Map<String, dynamic> p) async {
    return await pool.runTx((session) async {
      final result = await _processAddStockInSession(session, p);
      return jsonOk(result);
    });
  }

  Future<Map<String, dynamic>> _processAddStockInSession(
    dynamic session,
    Map<String, dynamic> p,
  ) async {
    final id = safeInt(p['id']) ?? safeInt(p['product_id']) ?? 0;
    final incSea = safeInt(p['sea_qty']) ?? 0;
    final incAir = safeInt(p['air_qty']) ?? 0;
    final incLocal = safeInt(p['local_qty']) ?? 0;
    final localPrice = safeDouble(p['local_price']) ?? 0.0;
    final newShipDate = safeDate(p['shipmentdate']);

    final warehouseIdFromBody = safeInt(p['warehouse_id']);
    final warehouseLocation = safeStr(p['warehouse_location']) ?? '';
    final totalIncoming = incSea + incAir + incLocal;

    print('=== ADD STOCK ===');
    print('product_id: $id');
    print('incSea: $incSea, incAir: $incAir, incLocal: $incLocal');
    print('totalIncoming: $totalIncoming');
    print('warehouseId from body: $warehouseIdFromBody');

    if (totalIncoming <= 0 && newShipDate == null) {
      return {'success': true, 'message': 'No changes'};
    }

    final res = await session.execute(
      'SELECT * FROM products WHERE id = $id FOR UPDATE',
    );

    if (res.isEmpty) {
      throw Exception('Product not found');
    }

    final row = res.first.toColumnMap();

    final oldQty = safeDouble(row['stock_qty']) ?? 0.0;
    final oldAvg = safeDouble(row['avg_purchase_price']) ?? 0.0;
    final yuan = safeDouble(row['yuan']) ?? 0.0;
    final curr = safeDouble(row['currency']) ?? 0.0;
    final weight = safeDouble(row['weight']) ?? 0.0;
    final seaTax = safeDouble(row['shipmenttax']) ?? 0.0;
    final airTax = safeDouble(row['shipmenttaxair']) ?? 0.0;

    print('DB before update → stock_qty: $oldQty, avg: $oldAvg');

    final seaUnitCost = (yuan * curr) + (weight * seaTax);
    final airUnitCost = (yuan * curr) + (weight * airTax);

    final incomingValue =
        (incSea * seaUnitCost) + (incAir * airUnitCost) + (incLocal * localPrice);

    final oldValue = oldQty * oldAvg;
    final newTotalQty = oldQty + totalIncoming;
    final newAvg =
        newTotalQty > 0 ? (oldValue + incomingValue) / newTotalQty : 0.0;

    print('newTotalQty: $newTotalQty, newAvg: $newAvg');

    var setClause = '''
      stock_qty = COALESCE(stock_qty, 0) + $totalIncoming,
      sea_stock_qty = COALESCE(sea_stock_qty, 0) + $incSea,
      air_stock_qty = COALESCE(air_stock_qty, 0) + $incAir,
      local_qty = COALESCE(local_qty, 0) + $incLocal,
      avg_purchase_price = $newAvg
    ''';

    if (newShipDate != null) {
      setClause += ', shipmentdate = ${dbVal(newShipDate)}';
    }

    await session.execute('UPDATE products SET $setClause WHERE id = $id');

    print('products table updated → stock_qty set to $newTotalQty');

    if (totalIncoming > 0) {
      final warehouseId =
          warehouseIdFromBody != null && warehouseIdFromBody > 0
              ? warehouseIdFromBody
              : await _getDefaultWarehouseId(session);

      // Check current pws qty before update
      final pwsBefore = await session.execute('''
        SELECT qty FROM product_warehouse_stock
        WHERE product_id = $id AND warehouse_id = $warehouseId
      ''');
      final qtyBefore = pwsBefore.isNotEmpty
          ? safeInt(pwsBefore.first.toColumnMap()['qty']) ?? 0
          : 0;
      print('pws qty BEFORE update: $qtyBefore');
      print('calling _setWarehouseStock with qty: ${newTotalQty.toInt()}');

      await _setWarehouseStock(
        session: session,
        productId: id,
        warehouseId: warehouseId,
        qty: newTotalQty.toInt(),
        location: warehouseLocation,
      );

      // Check current pws qty after update
      final pwsAfter = await session.execute('''
        SELECT qty FROM product_warehouse_stock
        WHERE product_id = $id AND warehouse_id = $warehouseId
      ''');
      final qtyAfter = pwsAfter.isNotEmpty
          ? safeInt(pwsAfter.first.toColumnMap()['qty']) ?? 0
          : 0;
      print('pws qty AFTER update: $qtyAfter');
    }

    print('=== END ADD STOCK ===');

    return {'success': true, 'new_avg': newAvg};
  }

  Future<Response> transferWarehouseStock(Request request) async {
    try {
      final body = Map<String, dynamic>.from(await parseBody(request) as Map);

      final productId = safeInt(body['product_id']) ?? 0;
      final fromWarehouseId = safeInt(body['from_warehouse_id']) ?? 0;
      final toWarehouseId = safeInt(body['to_warehouse_id']) ?? 0;
      final qty = safeInt(body['qty']) ?? 0;
      final toLocation = safeStr(body['to_location']) ?? '';

      if (productId <= 0 || fromWarehouseId <= 0 || toWarehouseId <= 0) {
        return jsonBad('Invalid warehouse transfer request');
      }

      if (fromWarehouseId == toWarehouseId) {
        return jsonBad('Source and destination warehouse cannot be same');
      }

      if (qty <= 0) return jsonBad('Invalid transfer quantity');

      return await pool.runTx((session) async {
        await _deductWarehouseStock(
          session: session,
          productId: productId,
          qty: qty,
          warehouseId: fromWarehouseId,
        );

        await _addToWarehouseStock(
          session: session,
          productId: productId,
          warehouseId: toWarehouseId,
          qty: qty,
          location: toLocation,
        );

        return jsonOk({'success': true});
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> updateProductWarehouseLocation(
    Request request,
    String idStr,
  ) async {
    try {
      final productId = int.parse(idStr);
      final body = Map<String, dynamic>.from(await parseBody(request) as Map);

      final warehouseId = safeInt(body['warehouse_id']) ?? 0;
      final location = safeStr(body['location']) ?? '';

      if (warehouseId <= 0) return jsonBad('Warehouse is required');

      await pool.execute('''
        INSERT INTO product_warehouse_stock (
          product_id, warehouse_id, qty, location, updated_at
        ) VALUES (
          $productId, $warehouseId, 0, ${dbVal(location)}, NOW()
        )
        ON CONFLICT (product_id, warehouse_id)
        DO UPDATE SET
          location = EXCLUDED.location,
          updated_at = NOW()
      ''');

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> recalculateAirSea(Request request) async {
    try {
      final p = await parseBody(request);
      final newCurr = safeDouble(p['currency']) ?? 0.0;

      if (newCurr <= 0) return jsonBad('Invalid currency');

      await pool.execute('''
        UPDATE products SET
          currency = $newCurr,
          avg_purchase_price = CASE
            WHEN stock_qty > 0 THEN
              (
                (
                  (stock_qty * avg_purchase_price) -
                  (
                    (COALESCE(sea_stock_qty, 0) * ((yuan * currency) + (weight * shipmenttax))) +
                    (COALESCE(air_stock_qty, 0) * ((yuan * currency) + (weight * shipmenttaxair)))
                  )
                )
                +
                (
                  (COALESCE(sea_stock_qty, 0) * ((yuan * $newCurr) + (weight * shipmenttax))) +
                  (COALESCE(air_stock_qty, 0) * ((yuan * $newCurr) + (weight * shipmenttaxair)))
                )
              ) / stock_qty
            ELSE 0
          END,
          sea = (yuan * $newCurr) + (weight * shipmenttax),
          air = (yuan * $newCurr) + (weight * shipmenttaxair)
        WHERE yuan > 0
      ''');

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> bulkUpdateStock(Request request) async {
    try {
      final body = await parseBody(request);
      final updates = body['updates'] as List? ?? [];

      await pool.runTx((session) async {
        for (final raw in updates) {
          final item = Map<String, dynamic>.from(raw as Map);

          final qty = safeInt(item['qty']) ?? 0;
          final id = safeInt(item['id']) ?? 0;
          final warehouseId = safeInt(item['warehouse_id']);

          if (id <= 0 || qty <= 0) continue;

          await _deductWarehouseStock(
            session: session,
            productId: id,
            qty: qty,
            warehouseId: warehouseId,
          );

          await session.execute('''
            UPDATE products SET
              stock_qty = GREATEST(0, COALESCE(stock_qty, 0) - $qty),
              local_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
                ELSE 0
              END,
              air_stock_qty = CASE
                WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
                WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty
                  THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
                ELSE 0
              END,
              sea_stock_qty = CASE
                WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty THEN sea_stock_qty
                ELSE GREATEST(0, sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0))))
              END
            WHERE id = $id
          ''');
        }
      });

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> updateProduct(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      final body = Map<String, dynamic>.from(await parseBody(request) as Map);
      final vals = _prepValues(body);

      await pool.execute('''
        UPDATE products SET
          name = ${vals['name']},
          category = ${vals['category']},
          brand = ${vals['brand']},
          model = ${vals['model']},
          weight = ${vals['weight']},
          yuan = ${vals['yuan']},
          sea = ${vals['sea']},
          air = ${vals['air']},
          agent = ${vals['agent']},
          wholesale = ${vals['wholesale']},
          shipmenttax = ${vals['shipmenttax']},
          shipmenttaxair = ${vals['shipmenttaxair']},
          shipmentdate = ${vals['shipmentdate']},
          shipmentno = ${vals['shipmentno']},
          currency = ${vals['currency']},
          stock_qty = ${vals['stock_qty']},
          avg_purchase_price = ${vals['avg_purchase_price']},
          sea_stock_qty = ${vals['sea_stock_qty']},
          air_stock_qty = ${vals['air_stock_qty']},
          local_qty = ${vals['local_qty']},
          alert_qty = ${vals['alert_qty']}
        WHERE id = $id
      ''');

      final warehouseId = safeInt(body['warehouse_id']);
      if (warehouseId != null && warehouseId > 0) {
        final stockQty = safeInt(body['stock_qty']) ?? 0;
        await pool.execute('''
          INSERT INTO product_warehouse_stock (
            product_id, warehouse_id, qty, location, updated_at
          ) VALUES (
            $id,
            $warehouseId,
            $stockQty,
            ${dbVal(safeStr(body['warehouse_location']) ?? '')},
            NOW()
          )
          ON CONFLICT (product_id, warehouse_id)
          DO UPDATE SET
            qty = EXCLUDED.qty,
            location = EXCLUDED.location,
            updated_at = NOW()
        ''');
      }

      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> deleteProduct(Request request, String idStr) async {
    try {
      final id = int.parse(idStr);
      await pool.execute('DELETE FROM products WHERE id = $id');
      return jsonOk({'success': true});
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> addToService(Request request) async {
    try {
      final p = await parseBody(request);

      final pid = safeInt(p['product_id']) ?? 0;
      final qty = safeInt(p['qty']) ?? 0;
      final cost = safeDouble(p['current_avg_price']) ?? 0.0;
      final type = dbVal(safeStr(p['type']) ?? 'Repair');
      final model = dbVal(safeStr(p['model']) ?? '');
      final warehouseId = safeInt(p['warehouse_id']);

      if (pid <= 0 || qty <= 0) return jsonBad('Invalid service request');

      return await pool.runTx((session) async {
        await _deductWarehouseStock(
          session: session,
          productId: pid,
          qty: qty,
          warehouseId: warehouseId,
        );

        await session.execute('''
          UPDATE products SET
            stock_qty = GREATEST(0, COALESCE(stock_qty, 0) - $qty),
            local_qty = CASE
              WHEN COALESCE(local_qty, 0) >= $qty THEN local_qty - $qty
              ELSE 0
            END,
            air_stock_qty = CASE
              WHEN COALESCE(local_qty, 0) >= $qty THEN air_stock_qty
              WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty
                THEN air_stock_qty - ($qty - COALESCE(local_qty, 0))
              ELSE 0
            END,
            sea_stock_qty = CASE
              WHEN (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0)) >= $qty THEN sea_stock_qty
              ELSE GREATEST(0, sea_stock_qty - ($qty - (COALESCE(local_qty, 0) + COALESCE(air_stock_qty, 0))))
            END
          WHERE id = $pid
        ''');

        await session.execute('''
          INSERT INTO product_logs (product_id, model, qty, type, return_cost)
          VALUES ($pid, $model, $qty, $type, $cost)
        ''');

        return jsonOk({'success': true});
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> returnFromService(Request request) async {
    try {
      final p = await parseBody(request);

      final logId = safeInt(p['log_id']) ?? 0;
      final qtyToReturn = safeInt(p['qty']) ?? 0;
      final warehouseIdFromBody = safeInt(p['warehouse_id']);
      final location = safeStr(p['warehouse_location']) ?? '';

      if (qtyToReturn <= 0) return jsonBad('Invalid qty');

      return await pool.runTx((session) async {
        final res = await session.execute(
          'SELECT * FROM product_logs WHERE id = $logId FOR UPDATE',
        );

        if (res.isEmpty) {
          return Response.notFound(
            jsonEncode({'error': 'Log not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final log = res.first.toColumnMap();

        if (log['status'] == 'returned') return jsonBad('Already returned');

        final pid = safeInt(log['product_id']) ?? 0;
        final currentLogQty = safeInt(log['qty']) ?? 0;

        if (qtyToReturn > currentLogQty) {
          return jsonBad('Cannot return. Limit exceeded.');
        }

        await session.execute('''
          UPDATE products
          SET
            stock_qty = COALESCE(stock_qty, 0) + $qtyToReturn,
            local_qty = COALESCE(local_qty, 0) + $qtyToReturn
          WHERE id = $pid
        ''');

        final warehouseId =
            warehouseIdFromBody != null && warehouseIdFromBody > 0
                ? warehouseIdFromBody
                : await _getDefaultWarehouseId(session);

        await _addToWarehouseStock(
          session: session,
          productId: pid,
          warehouseId: warehouseId,
          qty: qtyToReturn,
          location: location,
        );

        final remainingQty = currentLogQty - qtyToReturn;

        if (remainingQty == 0) {
          await session.execute(
            "UPDATE product_logs SET status = 'returned', qty = 0 WHERE id = $logId",
          );
        } else {
          await session.execute(
            'UPDATE product_logs SET qty = $remainingQty WHERE id = $logId',
          );
        }

        return jsonOk({'success': true});
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<Response> getServiceLogs(Request request) async {
    try {
      final res = await pool.execute(
        "SELECT * FROM product_logs WHERE status = 'active' ORDER BY created_at DESC",
      );

      return jsonOk({
        'data': res.map((r) => r.toColumnMap()).toList(),
      });
    } catch (e) {
      return jsonError(e);
    }
  }

  Future<int> _getDefaultWarehouseId(dynamic session) async {
    final found = await session.execute(
      'SELECT id FROM warehouses WHERE is_active = TRUE ORDER BY id ASC LIMIT 1',
    );

    if (found.isNotEmpty) {
      return safeInt(found.first.toColumnMap()['id']) ?? 1;
    }

    final created = await session.execute(
      "INSERT INTO warehouses (name) VALUES ('Main Warehouse') RETURNING id",
    );

    return safeInt(created.first.toColumnMap()['id']) ?? 1;
  }

  // SET (replace) — addStock এ use করো
  Future<void> _setWarehouseStock({
    required dynamic session,
    required int productId,
    required int warehouseId,
    required int qty,
    String location = '',
  }) async {
    if (qty <= 0) return;

    await session.execute('''
      INSERT INTO product_warehouse_stock (
        product_id, warehouse_id, qty, location, updated_at
      ) VALUES (
        $productId, $warehouseId, $qty, ${dbVal(location)}, NOW()
      )
      ON CONFLICT (product_id, warehouse_id)
      DO UPDATE SET
        qty = EXCLUDED.qty,
        location = CASE
          WHEN EXCLUDED.location <> '' THEN EXCLUDED.location
          ELSE product_warehouse_stock.location
        END,
        updated_at = NOW()
    ''');
  }

  // ADD (increment) — transfer/return এ use করো
  Future<void> _addToWarehouseStock({
    required dynamic session,
    required int productId,
    required int warehouseId,
    required int qty,
    String location = '',
  }) async {
    if (qty <= 0) return;

    await session.execute('''
      INSERT INTO product_warehouse_stock (
        product_id, warehouse_id, qty, location, updated_at
      ) VALUES (
        $productId, $warehouseId, $qty, ${dbVal(location)}, NOW()
      )
      ON CONFLICT (product_id, warehouse_id)
      DO UPDATE SET
        qty = product_warehouse_stock.qty + EXCLUDED.qty,
        location = CASE
          WHEN EXCLUDED.location <> '' THEN EXCLUDED.location
          ELSE product_warehouse_stock.location
        END,
        updated_at = NOW()
    ''');
  }

  Future<void> _deductWarehouseStock({
    required dynamic session,
    required int productId,
    required int qty,
    int? warehouseId,
  }) async {
    if (qty <= 0) return;

    if (warehouseId != null && warehouseId > 0) {
      final source = await session.execute('''
        SELECT id, qty
        FROM product_warehouse_stock
        WHERE product_id = $productId
          AND warehouse_id = $warehouseId
        FOR UPDATE
      ''');

      if (source.isEmpty) {
        throw Exception('Selected warehouse stock not found');
      }

      final sourceQty = safeInt(source.first.toColumnMap()['qty']) ?? 0;

      if (sourceQty < qty) {
        throw Exception('Not enough stock in selected warehouse');
      }

      await session.execute('''
        UPDATE product_warehouse_stock
        SET
          qty = qty - $qty,
          updated_at = NOW()
        WHERE product_id = $productId
          AND warehouse_id = $warehouseId
      ''');

      return;
    }

    var remaining = qty;

    final rows = await session.execute('''
      SELECT id, qty
      FROM product_warehouse_stock
      WHERE product_id = $productId
        AND qty > 0
      ORDER BY warehouse_id ASC
      FOR UPDATE
    ''');

    for (final row in rows) {
      if (remaining <= 0) break;

      final data = row.toColumnMap();
      final rowId = safeInt(data['id']) ?? 0;
      final currentQty = safeInt(data['qty']) ?? 0;
      final take = currentQty >= remaining ? remaining : currentQty;

      await session.execute('''
        UPDATE product_warehouse_stock
        SET
          qty = qty - $take,
          updated_at = NOW()
        WHERE id = $rowId
      ''');

      remaining -= take;
    }

    if (remaining > 0) {
      throw Exception('Not enough warehouse stock');
    }
  }

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

void main() async {
  final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '6543');
  final dbName = Platform.environment['DB_NAME'] ?? 'postgres';
  final dbUser = Platform.environment['DB_USER'] ?? 'postgres';
  final dbPass = Platform.environment['DB_PASS'] ?? '';
  final serverPort = int.parse(Platform.environment['PORT'] ?? '8080');

  print('Connecting to $dbHost:$dbPort...');

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
      queryMode: QueryMode.simple,
    ),
  );

  final app = Router();
  final api = ApiController();

  app.get('/', (Request request) => Response.ok('Active'));

  app.get('/products', api.fetchProducts);
  app.get('/products/shortlist', api.fetchShortList);
  app.get('/products/brands', api.fetchBrands);
  app.post('/products', api.insertProducts);
  app.post('/products/add', api.addSingleProduct);
  app.post('/products/add-stock', api.addStockMixed);
  app.post('/products/bulk-add-stock', api.bulkAddStockMixed);
  app.post('/products/transfer-warehouse', api.transferWarehouseStock);
  app.put('/products/recalculate-prices', api.recalculateAirSea);
  app.put('/products/bulk-update-stock', api.bulkUpdateStock);
  app.put('/products/<id>', api.updateProduct);
  app.put('/products/<id>/warehouse-location', api.updateProductWarehouseLocation);
  app.delete('/products/<id>', api.deleteProduct);

  app.get('/warehouses', api.fetchWarehouses);
  app.get('/warehouses/summary', api.fetchWarehouseSummary);
  app.post('/warehouses', api.createWarehouse);
  app.put('/warehouses/<id>', api.updateWarehouse);

  app.post('/service/add', api.addToService);
  app.post('/service/return', api.returnFromService);
  app.get('/service/list', api.getServiceLogs);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware())
      .addHandler(app.call);

  Timer.periodic(const Duration(minutes: 2), (_) async {
    try {
      await pool.execute('SELECT 1');
    } catch (e) {
      print('Ping failed: $e');
    }
  });

  await shelf_io.serve(handler, '0.0.0.0', serverPort);
  print('Server running on port $serverPort');
}
