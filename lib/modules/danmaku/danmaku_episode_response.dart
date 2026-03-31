class DanmakuEpisode {
  int episodeId;
  String episodeTitle;

  DanmakuEpisode({
    required this.episodeId,
    required this.episodeTitle,
  });

  factory DanmakuEpisode.fromJson(Map<String, dynamic> json) {
    return DanmakuEpisode(
      episodeId: json['episodeId'] ?? 0,
      episodeTitle: json['episodeTitle']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'episodeId': episodeId,
      'episodeTitle': episodeTitle,
    };
  }
}

class DanmakuEpisodeResponse {
  int bangumiId;
  List<DanmakuEpisode> episodes;
  int errorCode;
  bool success;
  String errorMessage;

  DanmakuEpisodeResponse({
    required this.bangumiId,
    required this.episodes,
    required this.errorCode,
    required this.success,
    required this.errorMessage,
  });

  factory DanmakuEpisodeResponse.fromJson(Map<String, dynamic> json) {
    final bangumi = json['bangumi'] as Map<String, dynamic>? ?? const {};
    final list = bangumi['episodes'] as List<dynamic>? ?? const [];
    final episodeList = list
        .whereType<Map<String, dynamic>>()
        .map((i) => DanmakuEpisode.fromJson(i))
        .toList();

    return DanmakuEpisodeResponse(
      bangumiId: bangumi['animeId'] ?? 0,
      episodes: episodeList,
      errorCode: json['errorCode'] ?? 0,
      success: json['success'] ?? false,
      errorMessage: json['errorMessage']?.toString() ?? '',
    );
  }

  factory DanmakuEpisodeResponse.fromTemplate() {
    return DanmakuEpisodeResponse(
      bangumiId: 0,
      episodes: [],
      errorCode: 0,
      success: false,
      errorMessage: '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'bangumi': episodes.map((episode) => episode.toJson()).toList(),
      'errorCode': errorCode,
      'success': success,
      'errorMessage': errorMessage,
    };
  }
}
