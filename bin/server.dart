import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:postgres/postgres.dart';

final connection = PostgreSQLConnection(
  'aws-1-ap-south-1.pooler.supabase.com', 
  6543, 
  'postgres', 
  username: 'postgres.eoppjzcrnmmrkliredpa', 
  password: 'Mum112029.', 
);

Future<Response> insertProducts(Request request) async {
  try {
    // Connect to DB
    await connection.open();

    // Get the incoming JSON body
    final body = await request.readAsString();
    final List<dynamic> products = jsonDecode(body);

    // Prepare the SQL insert statement
    for (var product in products) {
      await connection.query(
        '''
        INSERT INTO products (name, category, brand, model, weight, yuan, sea, air, agent, shipmentTax, shipmentNo, currency, stock_qty)
        VALUES (@name, @category, @brand, @model, @weight, @yuan, @sea, @air, @agent, @shipmentTax, @shipmentNo, @currency, @stock_qty)
        ''',
        substitutionValues: {
          'name': product['name'],
          'category': product['category'],
          'brand': product['brand'],
          'model': product['model'],
          'weight': product['weight'],
          'yuan': product['yuan'],
          'sea': product['sea'],
          'air': product['air'],
          'agent': product['agent'],
          'shipmentTax': product['shipmentTax'],
          'shipmentNo': product['shipmentNo'],
          'currency': product['currency'],
          'stock_qty': product['stock_qty'],
        },
      );
    }

    return Response.ok('Products inserted successfully');
  } catch (e) {
    return Response.internalServerError(body: 'Error: $e');
  } finally {
    await connection.close();
  }
}


Future<Response> fetchProducts(Request request) async {
  try {
    await connection.open();

    final results = await connection.query('SELECT * FROM products');

    List<Map<String, dynamic>> products = [];
    for (var row in results) {
      products.add({
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
        'shipmentTax': row[10],
        'shipmentNo': row[11],
        'currency': row[12],
        'stock_qty': row[13],
      });
    }

    return Response.ok(jsonEncode(products), headers: {'Content-Type': 'application/json'});
  } catch (e) {
    return Response.internalServerError(body: 'Error: $e');
  } finally {
    await connection.close();
  }
}

void main() async {
  final handler = const Pipeline()
      .addMiddleware(logRequests())  
      .addHandler((Request request) {
        if (request.method == 'POST') {
          return insertProducts(request); 
        } else if (request.method == 'GET') {
          return fetchProducts(request); 
        }
        return Response.notFound('Not Found');
      });

  final server = await shelf_io.serve(handler, 'localhost', 8080);
  print('Server listening at http://${server.address}:${server.port}');
}
