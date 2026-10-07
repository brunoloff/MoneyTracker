import 'package:http/http.dart' as http;
import 'runtime_types.dart';

Future<AppRuntime> createRuntime() async => AppRuntime(http.Client());
