import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist']),
  {
    files: ['**/*.{js,jsx}'],
    extends: [
      js.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    rules: {
      // Sacar una clave de un objeto con { clave, ...resto } deja la variable
      // sin usar a propósito; el guion bajo o el nombre lo avisan.
      'no-unused-vars': ['error', { varsIgnorePattern: '^_', ignoreRestSiblings: true }],
    },
  },
  {
    // Las pruebas corren en Node (`npm test`), no en el navegador: usan `process` y los
    // enlaces de módulos. Sin este bloque el lint las marcaría por globales inexistentes.
    files: ['pruebas/**/*.js'],
    languageOptions: { globals: globals.node },
  },
])
