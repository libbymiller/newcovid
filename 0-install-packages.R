# Install needed libraries -----------------------------------------------

chooseCRANmirror(graphics=FALSE, ind=1)

install.packages("data.table")   # for data.table, an enhanced (and faster) data.frame
install.packages("ggplot2")      # for plotting
install.packages("Rcpp")         # for running the C++ model backend
install.packages("RcppGSL")      # to use the GNU Scientific Library in C++ backend
install.packages("qs")           # for qsave and qread, faster equivalents of saveRDS and readRDS
install.packages("lubridate")    # for manipulating dates and times. NB requires stringr
install.packages("HDInterval")   # for summarizing results
install.packages("cowplot")      # for plotting grids


install.packages("zoo")  	 # for google_mobility.R
install.packages("remotes")
remotes::install_github("nicholasdavies/ogwrangler")   # for lockdown_analysis_region.R

install.packages("aod")  	 # for cog_analysis.R
