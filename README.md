# test-simple-stock-flow-infra

## 1. Qué es esto

Orquesta el sistema con Docker Compose: la base de datos MySQL 8.4 **vacía** (`db`), la API Laravel
(`api`) y la app React servida por nginx (`app`). **No** contiene esquema ni datos: ni una línea de DDL.
Las tablas, las cinco categorías y el administrador inicial los crea la API al arrancar.

Los otros cinco repositorios deben estar clonados como **hermanos** de este: el compose construye desde
`../test-simple-stock-flow-api` y `../test-simple-stock-flow-app`.

## 2. Cómo se levanta

Solo hace falta Docker. Desde esta carpeta:

```
cp .env.example .env        # en PowerShell: Copy-Item .env.example .env
```

Rellena en `.env` todos los valores vacíos. Para generar `APP_KEY` y `JWT_SIGNING_KEY` sin instalar nada:

```
docker run --rm php:8.3-cli php -r 'echo "base64:".base64_encode(random_bytes(32)),PHP_EOL;'
docker run --rm php:8.3-cli php -r 'echo bin2hex(random_bytes(32)),PHP_EOL;'
```

Luego:

```
docker compose up -d --build --wait
```

La app queda en `http://localhost:8080` (o el `APP_PORT` que fijes). Es el único puerto publicado.

**Modo desarrollo** (publica la API en `:8000` y la base en `:3306`):

```
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build --wait
```

No mezcles los dos modos sobre el mismo arranque: pasar de uno a otro recrea el contenedor de la API y le
quita el puerto publicado sin avisar.

### Variables

| Variable | Qué hace | Valor por defecto |
|---|---|---|
| `APP_PORT` | Puerto publicado de la app | `8080` |
| `CORS_ORIGINS` | Orígenes permitidos por la API | `http://localhost:8080` |
| `JWT_LIFETIME_MINUTES` | Vigencia del token | `60` |
| `DB_DATABASE`, `DB_USERNAME` | Base y usuario de la aplicación | `stockflow` |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | Claves de la base | **ninguno** |
| `APP_KEY` | Clave que exige Laravel | **ninguno** |
| `JWT_SIGNING_KEY` | Clave de firma del token | **ninguno** |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | Credenciales del administrador inicial | **ninguno** |

Ningún secreto tiene valor por defecto: si falta uno, `docker compose` falla nombrándolo.

## 3. Dónde están los datos

- **Base:** `stockflow` · **usuario:** `stockflow` · **puerto:** `3306` (solo con el modo desarrollo).
- Las claves salen de `DB_PASSWORD` y `DB_ROOT_PASSWORD` en tu `.env`.
- Para mirar las filas:

```
docker compose exec db mysql -u stockflow -p stockflow
```

- Tras el primer arranque deben existir 5 filas en `category` y 1 en `user`.
- Los datos persisten en el volumen `dbdata` y las imágenes en el volumen `media`.

## 4. Cómo se prueba

`verify.sh` comprueba el sistema desde fuera, con la pila ya levantada. Solo necesita Docker, que lo
ejecuta en un contenedor (la carpeta superior se monta para ver los repositorios hermanos):

```
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$(pwd)/..":/work -w /work/test-simple-stock-flow-infra docker:cli sh verify.sh
```

En PowerShell, sustituye `"$(pwd)/.."` por `"${PWD}\.."`. Termina con código 0 solo si todo pasa.

## 5. Qué falta

- `verify.sh` no puede pasar en verde hasta que existan las imágenes de `api` y `app`: el compose las
  construye desde sus repositorios, que hoy están vacíos.
- Las comprobaciones de catálogo, ventas y reporte las cubren los tests de `api` y la verificación de
  extremo a extremo (T-18), no este guion.
- El contrato que `api` y `app` deben cumplir con este compose: `api` escucha en el puerto 8000, tiene
  `curl` instalado para su healthcheck y responde `GET /health`; `app` escucha en el puerto 80 y proxea
  `/api/` y `/media/` hacia `api:8000`.
