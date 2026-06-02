FROM rocker/r-ver:4.3

WORKDIR /app

# System dependencies required by R packages used in the workflow.
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

RUN R -e "install.packages(c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel', 'paws'), repos='https://cloud.r-project.org/')"
RUN R -e "install.packages('biomod2', repos='https://cloud.r-project.org/')"

# Keep runtime directories consistent with the current workflow.
RUN mkdir -p /app/output /app/input /app/scripts

# Bake scripts into the image so they do not need to be uploaded to S3.
COPY scripts/ /app/scripts/
# Parameters must come from S3 input at startup, not from baked scripts.
RUN rm -f /app/scripts/parameters.txt /app/scripts/PARAMS

COPY entrypoint.sh /usr/local/bin/entrypoint-baked-scripts.sh
RUN chmod +x /usr/local/bin/entrypoint-baked-scripts.sh

# SCRIPT_NAME can be either a path relative to /app/scripts or an absolute path.
ENV TZ=UTC \
    AWS_DEFAULT_REGION=waw3-1 \
    SCRIPT_NAME=modelling/01_modeling_mixedPA.R \
    PARAMS=/app/input/parameters.txt \
    S3_INPUT_PREFIX=input \
    S3_OUTPUT_PREFIX=output

ENTRYPOINT ["/usr/local/bin/entrypoint-baked-scripts.sh"]
