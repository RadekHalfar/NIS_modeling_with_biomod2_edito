# Use rocker/r-ver as base image with R version 4.3
FROM rocker/r-ver:4.3

# Set working directory
WORKDIR /app

# Default timezone (same as previous compose setup)
ENV TZ=UTC

# Install system dependencies required for R packages
RUN apt-get update && apt-get install -y \
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
RUN R -e "install.packages(c('remotes', 'terra', 'dplyr', 'R.utils', 'dismo', 'maxnet', 'randomForest', 'doParallel'), repos='https://cloud.r-project.org/')"

# Install biomod2 from CRAN
RUN R -e "install.packages('biomod2', repos='https://cloud.r-project.org/')"

# Create output directory
RUN mkdir -p /app/output

# Copy the entire project into the container
COPY . /app/

# Set the working directory to the project root
WORKDIR /app

# Make the script executable
RUN chmod +x /app/modeling_mixedPA.R

# Set default command - users can override this with docker run arguments
# Example usage: docker run -v $(pwd)/output:/app/output biomod2-modeling \
#                <species> <algorithms> <PA_dist_min> <PA_dist_max> \
#                <CV_strategy> <CV_nb_rep> <CV_perc_or_NULL> <CV_k_or_NULL> \
#                <n_cores> <env_file> <outdir>

ENTRYPOINT ["Rscript", "/app/modeling_mixedPA.R"]
CMD ["Bugulaneritina", "GLM,GAM,RF,MAXNET", "2000", "100000", "kfold", "3", "NULL", "5", "4", "/app/myExpl_shelf_DISTFIX.tif", "/app/output"]
