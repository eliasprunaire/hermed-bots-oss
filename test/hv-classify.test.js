"use strict";

// Relais pour que `node --test` (npm test / CI) charge la suite du skill,
// qui vit sous `.cursor/` et échappe aux globs par défaut
require("../.cursor/skills/verify-hermed-bots/test/classify.test.js");
