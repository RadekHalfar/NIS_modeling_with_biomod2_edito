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

# Create output and scripts directories
RUN mkdir -p /app/output /app/scripts

# Copy the entire project into the container
COPY . /app/

# Set the working directory to the project root
WORKDIR /app

# Default entrypoint configuration (can be overridden with -e)
ENV SCRIPTS_DIR=/app/scripts
ENV SCRIPT_NAME=modelling/01_modeling_mixedPA.R

# Make all R scripts and the entrypoint executable
RUN find /app/scripts -name "*.R" -type f -exec chmod +x {} \; && \
    chmod +x /app/scripts/entrypoint.sh /app/modeling_mixedPA.R 2>/dev/null || true

# Set entrypoint to the wrapper script that routes to different R scripts
# Scripts mounted at /app/scripts can be swapped without rebuilding
# Example usage:
#   docker run -v $(pwd)/scripts:/app/scripts -v $(pwd)/output:/app/output -v $(pwd)/input:/app/input biomod2-modeling \
#                modeling_mixedPA.R Bugulaneritina GLM,GAM,RF,MAXNET 2000 100000 kfold 3 NULL 5 4 /app/input/myExpl_shelf_DISTFIX.tif /app/output
#
# To run a different script:
#   docker run ... biomod2-modeling other_script.R arg1 arg2 ...
#
# To see available scripts:
#   docker run ... biomod2-modeling (no arguments)

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
#CMD ["modeling_mixedPA.R", "Bugulaneritina", "GLM,GAM,RF,MAXNET", "2000", "100000", "kfold", "3", "NULL", "5", "4", "/app/input/myExpl_shelf_DISTFIX.tif", "/app/output", "scripts", "input"]
