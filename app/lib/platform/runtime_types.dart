import 'package:http/http.dart' as http;

class AppRuntime {
  final http.Client client;
  final bool desktop;
  final String? dataPath;
  AppRuntime(this.client, {this.desktop = false, this.dataPath});
  Future<void> close() async {
    client.close();
  }
}
