FROM rocker/r-ver:4.3

WORKDIR /app

# System dependencies required by R packages used in the workflow.
# terra's current CRAN release needs GDAL >= 3.8 (it calls the 3-arg
# GDALMDArray::AsClassicDataset overload added in that version). Ubuntu
# 22.04's stock repo only has GDAL 3.4.1, so libgdal-dev must come from
# ubuntugis-unstable instead, or `terra` (and tidyterra/biomod2, which
# depend on it) fail to compile with:
#   "error: no matching function for call to 'GDALMDArray::AsClassicDataset(...)'"
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    gnupg \
    && add-apt-repository -y ppa:ubuntugis/ubuntugis-unstable \
    && apt-get update && apt-get install -y \
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

# install.packages() does not make R (or the RUN step) exit non-zero when a
# package fails to install - it only prints a warning. Without an explicit
# post-install check, a broken build would look successful here and only
# fail later at runtime with "there is no package called X". So every
# package actually used by scripts/modelling/*.R is verified with
# requireNamespace() below, which does stop the build on failure.
RUN R -e "install.packages(c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel', 'paws', 'ggplot2', 'tidyterra', 'biomod2'), repos='https://cloud.r-project.org/')"
RUN R -e "\
required <- c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel', 'paws', 'ggplot2', 'tidyterra', 'biomod2'); \
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]; \
if (length(missing) > 0) stop('Failed to install required package(s): ', paste(missing, collapse = ', '))"

# Keep runtime directories consistent with the current workflow.
RUN mkdir -p /app/output /app/input /app/scripts

# Bake scripts into the image so they do not need to be uploaded to S3.
COPY scripts/ /app/scripts/
# Parameters must come from S3 input at startup, not from baked scripts.
RUN rm -f /app/scripts/parameters.txt /app/scripts/PARAMS

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY entrypoint_baked_scripts.sh /usr/local/bin/entrypoint-baked-scripts.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint-baked-scripts.sh

# SCRIPT_NAME is a path relative to /app/scripts.
# PARAMS is intentionally not set here: entrypoint.sh defaults it to
# /app/scripts/PARAMS (synced down from S3 alongside the scripts), and an
# ENV default here would shadow that at runtime.
ENV TZ=UTC \
    AWS_DEFAULT_REGION=waw3-1 \
    SCRIPT_NAME=modelling/01_modeling_mixedPA.R \
    S3_SCRIPTS_PREFIX=scripts \
    S3_INPUT_PREFIX=input \
    S3_OUTPUT_PREFIX=output

#ENTRYPOINT ["/usr/local/bin/entrypoint-baked-scripts.sh"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
