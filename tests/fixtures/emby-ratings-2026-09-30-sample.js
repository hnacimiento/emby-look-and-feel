/*!
 * Excerpt with the exact shape of upstream emby-ratings.js since 2026-09-30
 * (CONFIG block + OMDb call). Used by tests/unit/test_ratings_omdb_css.sh.
 */
(function(){
    const CONFIG = {
        enableAwards: true,
        enableCustomRatings: true,
		MDBLIST_API_KEY: '', // API Key from https://mdblist.com/
        TMDB_API_KEY: '', // API Key from https://www.themoviedb.org/
        KINOPOISK_API_KEY: '', // API key from https://kinopoiskapiunofficial.tech/
		OMDB_API_KEY: '', // Own key for standalone use; plugin key stays on the server.
        enableIMDb: true,
        CACHE_TTL_HOURS: 168, // in hours
        CORS_PROXY_URL: '' // e.g. 'https://cors.yourdomain.com/proxy/'
    };
    const omdb = imdb => 'https://www.omdbapi.com/?i='+encodeURIComponent(imdb)+'&apikey='+encodeURIComponent(CONFIG.OMDB_API_KEY.trim());
    const tmdb = id => `https://api.themoviedb.org/3/tv/${id}?api_key=${CONFIG.TMDB_API_KEY}`;
})();
