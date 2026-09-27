// Fixture para tests de set_or_die_property_string / set_or_die_property_raw:
// imita el estilo 'NAME: value,' que usan Spotlight.js y emby-ratings.js
// (ver docs/ARCHITECTURE.md, "Addon injection mechanisms").
const CONFIG = {
    TMDB_API_KEY: 'PLACEHOLDER',
    CORS_PROXY_URL: 'https://old-proxy.example.com', // debe poder quedar vacío
    vignetteColorTop: '#000000',
    enableIMDb: true,
};
