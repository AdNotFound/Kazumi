import 'package:mobx/mobx.dart';

class Road {
  String name;
  List<String> data;
  ObservableList<String> identifier;

  Road({
    required this.name,
    required this.data,
    required List<String> identifier,
  }) : identifier = ObservableList<String>.of(identifier);
}
