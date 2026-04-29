# Use rocker/r-ver as base image with R version 4.3
FROM rocker/r-ver:4.3

# Set working directory
WORKDIR /app

# Default timezone (same as previous compose setup)
ENV TZ=UTC

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
# Scripts are downloaded from S3 at container startup — not mounted or baked into the image.
RUN mkdir -p /app/output /app/input /app/scripts

# Copy entrypoint outside /app/scripts so bind mounts cannot hide it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default entrypoint configuration (override with -e at docker run time).
# S3_SCRIPTS_PREFIX + SCRIPT_NAME form the S3 key: $S3_SCRIPTS_PREFIX/$SCRIPT_NAME
# The script is downloaded to /app/scripts/$SCRIPT_NAME before execution.
ENV SCRIPT_NAME=modeling_mixedPA.R
ENV S3_SCRIPTS_PREFIX=scripts

# Set entrypoint to the wrapper script.
# At startup it downloads SCRIPT_NAME from S3 (using AWS_* / S3_BUCKET env vars),
# then executes it with any extra CLI arguments forwarded.
#
# Minimal run (all config via -e):
#   docker run --rm \
#     -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
#     -e AWS_S3_ENDPOINT=... -e S3_BUCKET=... \
#     -e SCRIPT_NAME=modeling_mixedPA.R \
#     -v $(pwd)/output:/app/output \
#     biomod2-modeling \
#     Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/input/myExpl_shelf.tif /app/output

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# CMD provides default R script arguments forwarded to Rscript.
# Override at docker run time by appending args after the image name.
# SCRIPT_NAME, S3_BUCKET and AWS_* credentials must always be supplied via -e.
CMD ["Bugulaneritina", "GLM,GAM,RF,MAXNET", "2000", "100000", "kfold", "3", "NULL", "5", "4", "/app/input/myExpl_shelf_DISTFIX.tif", "/app/output", "/app/scripts", "/app/input"]
