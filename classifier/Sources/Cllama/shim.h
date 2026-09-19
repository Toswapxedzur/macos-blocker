#pragma once
#include <llama.h>
// Exposes ggml_backend_load_all_from_path so a packaged .app can load its
// bundled ggml backends (Metal/CPU/BLAS) from a known directory instead of
// relying on ggml's compiled-in Homebrew libexec path.
#include <ggml-backend.h>
