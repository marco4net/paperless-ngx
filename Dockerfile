# syntax=docker/dockerfile:1.4

# Pull the installer images from the library
# These are all built previously
# They provide either a .deb or .whl

ARG JBIG2ENC_VERSION
ARG QPDF_VERSION
ARG PIKEPDF_VERSION
ARG PSYCOPG2_VERSION

FROM ghcr.io/paperless-ngx/paperless-ngx/builder/jbig2enc:${JBIG2ENC_VERSION} as jbig2enc-builder
FROM ghcr.io/paperless-ngx/paperless-ngx/builder/qpdf:${QPDF_VERSION} as qpdf-builder
FROM ghcr.io/paperless-ngx/paperless-ngx/builder/pikepdf:${PIKEPDF_VERSION} as pikepdf-builder
FROM ghcr.io/paperless-ngx/paperless-ngx/builder/psycopg2:${PSYCOPG2_VERSION} as psycopg2-builder

FROM --platform=$BUILDPLATFORM node:16-bullseye-slim AS compile-frontend

# This stage compiles the frontend
# This stage runs once for the native platform, as the outputs are not
# dependent on target arch
# Inputs: None

COPY ./src-ui /src/src-ui

WORKDIR /src/src-ui
RUN set -eux \
  && npm update npm -g \
  && npm ci --omit=optional
RUN set -eux \
  && ./node_modules/.bin/ng build --configuration production

FROM --platform=$BUILDPLATFORM python:3.9-slim-bullseye as pipenv-base

# This stage generates the requirements.txt file using pipenv
# This stage runs once for the native platform, as the outputs are not
# dependent on target arch
# This way, pipenv dependencies are not left in the final image
# nor can pipenv mess up the final image somehow
# Inputs: None

WORKDIR /usr/src/pipenv

COPY Pipfile* ./

RUN set -eux \
  && echo "Installing pipenv" \
    && python3 -m pip install --no-cache-dir --upgrade pipenv \
  && echo "Generating requirement.txt" \
    && pipenv requirements > requirements.txt

FROM python:3.9-slim-bullseye as main-app

LABEL org.opencontainers.image.authors="paperless-ngx team <hello@paperless-ngx.com>"
LABEL org.opencontainers.image.documentation="https://docs.paperless-ngx.com/"
LABEL org.opencontainers.image.source="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.url="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive

#
# Begin installation and configuration
# Order the steps below from least often changed to most
#

# copy jbig2enc
# Basically will never change again
COPY --from=jbig2enc-builder /usr/src/jbig2enc/src/.libs/libjbig2enc* /usr/local/lib/
COPY --from=jbig2enc-builder /usr/src/jbig2enc/src/jbig2 /usr/local/bin/
COPY --from=jbig2enc-builder /usr/src/jbig2enc/src/*.h /usr/local/include/

# Packages need for running
ARG RUNTIME_PACKAGES="\
  # Python
  python3 \
  python3-pip \
  python3-setuptools \
  # General utils
  curl \
  # Docker specific
  gosu \
  # Timezones support
  tzdata \
  # fonts for text file thumbnail generation
  fonts-liberation \
  gettext \
  ghostscript \
  gnupg \
  icc-profiles-free \
  imagemagick \
  # Image processing
  liblept5 \
  liblcms2-2 \
  libtiff5 \
  libfreetype6 \
  libwebp6 \
  libopenjp2-7 \
  libimagequant0 \
  libraqm0 \
  libjpeg62-turbo \
  # PostgreSQL
  libpq5 \
  postgresql-client \
  # MySQL / MariaDB
  mariadb-client \
  # For Numpy
  libatlas3-base \
  # OCRmyPDF dependencies
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-deu \
  tesseract-ocr-fra \
  tesseract-ocr-ita \
  tesseract-ocr-spa \
  unpaper \
  pngquant \
  # pikepdf / qpdf
  jbig2dec \
  libxml2 \
  libxslt1.1 \
  libgnutls30 \
  # Mime type detection
  file \
  libmagic1 \
  media-types \
  zlib1g \
  # Barcode splitter
  libzbar0 \
  poppler-utils \
  # RapidFuzz on armv7
  libatomic1"

# Install basic runtime packages.
# These change very infrequently
RUN set -eux \
  echo "Installing system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${RUNTIME_PACKAGES} \
    && rm -rf /var/lib/apt/lists/* \
  && echo "Installing supervisor" \
    && python3 -m pip install --default-timeout=1000 --upgrade --no-cache-dir supervisor==4.2.4

# Copy gunicorn config
# Changes very infrequently
WORKDIR /usr/src/paperless/

COPY gunicorn.conf.py .

# setup docker-specific things
# Use mounts to avoid copying installer files into the image
# These change sometimes, but rarely
WORKDIR /usr/src/paperless/src/docker/

COPY [ \
  "docker/imagemagick-policy.xml", \
  "docker/supervisord.conf", \
  "docker/docker-entrypoint.sh", \
  "docker/docker-prepare.sh", \
  "docker/paperless_cmd.sh", \
  "docker/wait-for-redis.py", \
  "docker/management_script.sh", \
  "docker/flower-conditional.sh", \
  "docker/install_management_commands.sh", \
  "/usr/src/paperless/src/docker/" \
]

RUN set -eux \
  && echo "Configuring ImageMagick" \
    && mv imagemagick-policy.xml /etc/ImageMagick-6/policy.xml \
  && echo "Configuring supervisord" \
    && mkdir /var/log/supervisord /var/run/supervisord \
    && mv supervisord.conf /etc/supervisord.conf \
  && echo "Setting up Docker scripts" \
    && mv docker-entrypoint.sh /sbin/docker-entrypoint.sh \
    && chmod 755 /sbin/docker-entrypoint.sh \
    && mv docker-prepare.sh /sbin/docker-prepare.sh \
    && chmod 755 /sbin/docker-prepare.sh \
    && mv wait-for-redis.py /sbin/wait-for-redis.py \
    && chmod 755 /sbin/wait-for-redis.py \
    && mv paperless_cmd.sh /usr/local/bin/paperless_cmd.sh \
    && chmod 755 /usr/local/bin/paperless_cmd.sh \
    && mv flower-conditional.sh /usr/local/bin/flower-conditional.sh \
    && chmod 755 /usr/local/bin/flower-conditional.sh \
  && echo "Installing managment commands" \
    && chmod +x install_management_commands.sh \
    && ./install_management_commands.sh

# Install the built packages from the installer library images
# Use mounts to avoid copying installer files into the image
# These change sometimes
RUN --mount=type=bind,from=qpdf-builder,target=/qpdf \
    --mount=type=bind,from=psycopg2-builder,target=/psycopg2 \
    --mount=type=bind,from=pikepdf-builder,target=/pikepdf \
  set -eux \
  && echo "Installing qpdf" \
    && apt-get install --yes --no-install-recommends /qpdf/usr/src/qpdf/libqpdf29_*.deb \
    && apt-get install --yes --no-install-recommends /qpdf/usr/src/qpdf/qpdf_*.deb \
  && echo "Installing pikepdf and dependencies" \
    && python3 -m pip install --no-cache-dir /pikepdf/usr/src/wheels/pyparsing*.whl \
    && python3 -m pip install --no-cache-dir /pikepdf/usr/src/wheels/packaging*.whl \
    && python3 -m pip install --no-cache-dir /pikepdf/usr/src/wheels/lxml*.whl \
    && python3 -m pip install --no-cache-dir /pikepdf/usr/src/wheels/Pillow*.whl \
    && python3 -m pip install --no-cache-dir /pikepdf/usr/src/wheels/pikepdf*.whl \
    && python3 -m pip list \
  && echo "Installing psycopg2" \
    && python3 -m pip install --no-cache-dir /psycopg2/usr/src/wheels/psycopg2*.whl \
    && python3 -m pip list

WORKDIR /usr/src/paperless/src/

# Python dependencies
# Change pretty frequently
COPY --from=pipenv-base /usr/src/pipenv/requirements.txt ./

# Packages needed only for building a few quick Python
# dependencies
ARG BUILD_PACKAGES="\
  build-essential \
  git \
  default-libmysqlclient-dev \
  python3-dev"

RUN set -eux \
  && echo "Installing build system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${BUILD_PACKAGES} \
    && python3 -m pip install --no-cache-dir --upgrade wheel \
  && echo "Installing Python requirements" \
    && python3 -m pip install --default-timeout=1000 --no-cache-dir --requirement requirements.txt \
  && echo "Installing NLTK data" \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/local/share/nltk_data" snowball_data \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/local/share/nltk_data" stopwords \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/local/share/nltk_data" punkt \
  && echo "Cleaning up image" \
    && apt-get -y purge ${BUILD_PACKAGES} \
    && apt-get -y autoremove --purge \
    && apt-get clean --yes \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/* \
    && rm -rf /var/tmp/* \
    && rm -rf /var/cache/apt/archives/* \
    && truncate -s 0 /var/log/*log

# copy backend
COPY ./src ./

# copy frontend
COPY --from=compile-frontend /src/src/documents/static/frontend/ ./documents/static/frontend/

# add users, setup scripts
RUN set -eux \
  && addgroup --gid 1000 paperless \
  && useradd --uid 1000 --gid paperless --home-dir /usr/src/paperless paperless \
  && chown -R paperless:paperless ../ \
  && gosu paperless python3 manage.py collectstatic --clear --no-input \
  && gosu paperless python3 manage.py compilemessages

VOLUME ["/usr/src/paperless/data", \
        "/usr/src/paperless/media", \
        "/usr/src/paperless/consume", \
        "/usr/src/paperless/export"]

ENTRYPOINT ["/sbin/docker-entrypoint.sh"]

EXPOSE 8000

CMD ["/usr/local/bin/paperless_cmd.sh"]
