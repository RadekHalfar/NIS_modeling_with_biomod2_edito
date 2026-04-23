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
    && rm -rf /var/lib/apt/lists/*

# Install R packages
RUN R -e "install.packages(c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel', 'paws'), repos='https://cloud.r-project.org/')"

# Install biomod2 from CRAN
RUN R -e "install.packages('biomod2', repos='https://cloud.r-project.org/')"

# Create app directories.
# Scripts are intentionally NOT copied into the image and must be mounted.
RUN mkdir -p /app/output /app/input /app/scripts

# Copy entrypoint outside /app/scripts so bind mounts cannot hide it.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default entrypoint configuration (can be overridden with -e at docker run time)
# SCRIPTS_DIR + SCRIPT_NAME together form the full path: $SCRIPTS_DIR/$SCRIPT_NAME
ENV SCRIPTS_DIR=/app/scripts
ENV SCRIPT_NAME=modeling_mixedPA.R

# Set entrypoint to the wrapper script that routes to different R scripts.
# R scripts are loaded from mounted volume only (not from the image).
#
# Run default script (SCRIPT_NAME env var):
#   docker run -v $(pwd)/scripts:/app/scripts -v $(pwd)/output:/app/output -v $(pwd)/input:/app/input biomod2-modeling \
#              Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/input/myExpl_shelf.tif /app/output /app/scripts /app/input
#
# Override script via env var (no rebuild needed):
#   docker run -e SCRIPT_NAME=analysis.R -v $(pwd)/scripts:/app/scripts ... biomod2-modeling ...
#
# Override script via CLI arg (highest priority):
#   docker run ... biomod2-modeling analysis.R arg1 arg2 ...

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
#CMD ["modeling_mixedPA.R", "Bugulaneritina", "GLM,GAM,RF,MAXNET", "2000", "100000", "kfold", "3", "NULL", "5", "4", "/app/input/myExpl_shelf_DISTFIX.tif", "/app/output", "scripts", "input"]
