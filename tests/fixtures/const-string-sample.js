// Fixture para tests de set_or_die_const_string / set_or_inject_const_string /
// set_if_declared_const_string: imita el estilo 'const NAME = value;' que
// usan emby-elsewhere.js y Reviews.js (ver docs/ARCHITECTURE.md, "Addon
// injection mechanisms").
const TMDB_API_KEY = 'PLACEHOLDER';
const DEFAULT_REGION = 'US'; // comentario que debe sobrevivir la edición
const OTHER_THING_WITH_AR_INSIDE = 'this contains AR as a substring, should not confuse the verifier';
