class DanmakuAnime {
  int animeId;
  String animeTitle;
  String type;
  String typeDescription;
  String imageUrl;
  DateTime startDate;
  int episodeCount;
  double rating;
  bool isFavorited;

  DanmakuAnime({
    required this.animeId,
    required this.animeTitle,
    required this.type,
    required this.typeDescription,
    required this.imageUrl,
    required this.startDate,
    required this.episodeCount,
    required this.rating,
    required this.isFavorited,
  });

  factory DanmakuAnime.fromJson(Map<String, dynamic> json) {
    final startDateValue = json['startDate']?.toString();
    final ratingValue = json['rating'];
    return DanmakuAnime(
      animeId: json['animeId'] ?? 0,
      animeTitle: json['animeTitle']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      typeDescription: json['typeDescription']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      startDate: startDateValue == null || startDateValue.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.tryParse(startDateValue) ??
              DateTime.fromMillisecondsSinceEpoch(0),
      episodeCount: json['episodeCount'] ?? 0,
      rating: ratingValue is num ? ratingValue.toDouble() : 0,
      isFavorited: json['isFavorited'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'animeId': animeId,
      'animeTitle': animeTitle,
      'type': type,
      'typeDescription': typeDescription,
      'imageUrl': imageUrl,
      'startDate': startDate.toIso8601String(),
      'episodeCount': episodeCount,
      'rating': rating,
      'isFavorited': isFavorited,
    };
  }
}

class DanmakuSearchResponse {
  List<DanmakuAnime> animes;
  int errorCode;
  bool success;
  String errorMessage;

  DanmakuSearchResponse({
    required this.animes,
    required this.errorCode,
    required this.success,
    required this.errorMessage,
  });

  factory DanmakuSearchResponse.fromJson(Map<String, dynamic> json) {
    final list = json['animes'] as List<dynamic>? ?? const [];
    final animeList = list
        .whereType<Map<String, dynamic>>()
        .map((i) => DanmakuAnime.fromJson(i))
        .toList();

    return DanmakuSearchResponse(
      animes: animeList,
      errorCode: json['errorCode'] ?? 0,
      success: json['success'] ?? false,
      errorMessage: json['errorMessage']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'animes': animes.map((anime) => anime.toJson()).toList(),
      'errorCode': errorCode,
      'success': success,
      'errorMessage': errorMessage,
    };
  }
}
