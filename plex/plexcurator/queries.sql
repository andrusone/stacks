-- name: by_video_class
SELECT
    video_class,
    COUNT(*) AS movies,
    ROUND(SUM(size) / 1e9, 1) AS gb
FROM v_movie
WHERE state = 'present'
GROUP BY video_class
ORDER BY gb DESC;
-- name: by_hdr
SELECT
    COALESCE(hdr, 'unprobed') AS hdr,
    COUNT(*) AS movies,
    ROUND(SUM(size) / 1e9, 1) AS gb
FROM v_movie
WHERE state = 'present'
GROUP BY 1
ORDER BY movies DESC;
-- name: hdr_by_video_class
SELECT
    video_class,
    COALESCE(hdr, 'unprobed') AS hdr,
    COUNT(*) AS movies
FROM v_movie
WHERE state = 'present'
GROUP BY 1, 2
ORDER BY video_class ASC, movies DESC;
-- name: dolby_vision_profiles
SELECT
    dv_profile,
    COALESCE(dv_fallback, 'none') AS fallback_layer,
    COUNT(*) AS movies
FROM v_movie
WHERE state = 'present' AND dolby_vision = 1
GROUP BY 1, 2
ORDER BY movies DESC;
-- name: hdr_stars
SELECT
    stars,
    COALESCE(hdr, 'unprobed') AS hdr,
    COUNT(*) AS movies,
    ROUND(AVG(peak_percent), 0) AS avg_peak
FROM v_movie
WHERE state = 'present'
GROUP BY 1, 2
ORDER BY stars, hdr;
-- name: by_audio_class
SELECT
    audio_class,
    channels,
    COUNT(*) AS movies
FROM v_movie
WHERE state = 'present'
GROUP BY audio_class, channels
ORDER BY movies DESC;
-- name: where_content_sits
SELECT
    zone,
    COUNT(*) AS movies,
    ROUND(SUM(size) / 1e9, 1) AS gb
FROM v_movie
WHERE state = 'present'
GROUP BY zone;
-- name: codec_mix
SELECT
    v.codec_name AS video_codec,
    a.codec_name AS audio_codec,
    COUNT(*) AS movies
FROM v_video AS v
INNER JOIN v_audio AS a ON v.file_id = a.file_id
GROUP BY v.codec_name, a.codec_name
ORDER BY movies DESC;
-- name: audio_languages
SELECT
    language,
    codec_name,
    COUNT(*) AS streams
FROM v_audio
GROUP BY 1, 2
ORDER BY streams DESC;
-- name: any_ffprobe_field
SELECT
    JSON_EXTRACT(raw_json, '$.format.format_long_name') AS container,
    COUNT(*) AS files,
    ROUND(AVG(JSON_EXTRACT(raw_json, '$.format.bit_rate')) / 1e6, 1) AS avg_mbps
FROM source_record
WHERE source = 'ffprobe'
GROUP BY 1;
-- name: any_plex_field
SELECT
    JSON_EXTRACT(raw_json, '$.contentRating') AS content_rating,
    COUNT(*) AS movies
FROM source_record
WHERE source = 'plex'
GROUP BY 1
ORDER BY movies DESC;
-- name: stars_vs_resolution
SELECT
    stars,
    video_class,
    COUNT(*) AS movies,
    ROUND(AVG(peak_percent), 0) AS avg_peak
FROM v_movie
WHERE state = 'present'
GROUP BY stars, video_class
ORDER BY stars, video_class;
-- name: abandoned_movies
SELECT
    title,
    year,
    peak_percent,
    DATETIME(first_watched_at, 'unixepoch') AS first_watched
FROM movie
WHERE peak_percent BETWEEN 1 AND 49
ORDER BY peak_percent;
-- name: taste_by_decade
SELECT
    (year / 10) * 10 AS decade,
    COUNT(*) AS watched,
    ROUND(AVG(rating) / 2, 2) AS avg_stars
FROM movie
WHERE watched = 1
GROUP BY decade
ORDER BY decade;
-- name: days_from_born_to_watched
SELECT
    title,
    ROUND((first_watched_at - born_at) / 86400.0, 1) AS days_waiting
FROM movie
WHERE first_watched_at IS NOT NULL AND born_at IS NOT NULL
ORDER BY days_waiting DESC
LIMIT 25;
-- name: problem_movies
SELECT
    m.title,
    m.year,
    COUNT(*) AS issues,
    MAX(i.message) AS sample
FROM issue AS i
INNER JOIN movie AS m ON i.movie_id = m.id
GROUP BY m.id
ORDER BY issues DESC
LIMIT 25;
-- name: timeline
SELECT
    m.title,
    e.kind,
    e.value,
    e.detail,
    DATETIME(e.ts, 'unixepoch') AS at
FROM event AS e
INNER JOIN movie AS m ON e.movie_id = m.id
ORDER BY e.ts DESC
LIMIT 100;
-- name: retired_audit
SELECT
    m.title,
    m.year,
    d.rule,
    d.reason,
    d.status,
    DATETIME(d.executed_at, 'unixepoch') AS retired,
    ROUND(d.size_bytes / 1e9, 1) AS gb
FROM deletion AS d
INNER JOIN movie AS m ON d.movie_id = m.id
ORDER BY d.selected_at DESC;
-- name: unidentified
SELECT
    m.id,
    m.title,
    f.path
FROM movie AS m
LEFT JOIN file AS f ON m.id = f.movie_id
WHERE m.unidentified = 1 AND m.state = 'present';
-- name: library_growth
SELECT
    STRFTIME('%Y-%m', born_at, 'unixepoch') AS month,
    COUNT(*) AS born
FROM movie
GROUP BY month
ORDER BY month;
