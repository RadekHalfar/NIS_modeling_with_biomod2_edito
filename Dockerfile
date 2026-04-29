# Use rocker/r-ver as base image with R version 4.3
FROM rocker/r-ver:4.3

# Set working directory
WORKDIR /app

# Install system dependencies required for R packages
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    libgdal-dev \
    libproj-dev \
    libgeos-dev \
    libudunits2-dev \
    libnetcdf-dev \
    libsqlite3-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    git \
    awscli \
    && rm -rf /var/lib/apt/lists/*

# Install R packages
RUN R -e "install.packages(c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel', 'paws'), repos='https://cloud.r-project.org/')"

# Install biomod2 from CRAN
RUN R -e "install.packages('biomod2', repos='https://cloud.r-project.org/')"

# Create app directories.
# Scripts are synced from S3 at container startup — not mounted or baked into the image.
RUN mkdir -p /app/output /app/input /app/scripts

# Copy entrypoint outside /app/scripts so bind mounts cannot hide it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# Environment variable defaults (override any with -e at docker run time).
# Required at runtime — no default, must always be passed via -e:
#   AWS_ACCESS_KEY_ID       S3-compatible access key
#   AWS_SECRET_ACCESS_KEY   S3-compatible secret key
#   AWS_S3_ENDPOINT         Custom S3 endpoint URL (e.g. s3.waw3-1.cloudferro.com)
#   S3_BUCKET               Bucket for scripts, input data, and output upload
# ---------------------------------------------------------------------------
ENV TZ=UTC \
    AWS_DEFAULT_REGION=waw3-1 \
    SCRIPT_NAME=modeling_mixedPA.R \
    S3_SCRIPTS_PREFIX=scripts \
    S3_INPUT_PREFIX=input \
    S3_OUTPUT_PREFIX=output

# Set entrypoint to the wrapper script.
# At startup it syncs the entire S3_SCRIPTS_PREFIX folder from S3 (including PARAMS),
# then executes SCRIPT_NAME. All run parameters are read from the PARAMS file.
#
# Minimal run (all config via -e):
#   docker run --rm \
#     -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
#     -e AWS_S3_ENDPOINT=... -e S3_BUCKET=... \
#     -e SCRIPT_NAME=modeling_mixedPA.R \
#     -v $(pwd)/output:/app/output \
#     biomod2-modeling

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# No CMD args needed — all parameters are supplied via the PARAMS file in S3_SCRIPTS_PREFIX.
