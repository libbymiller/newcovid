# covidm
Dynamic model of SARS-nCoV-2 transmission.

This model is under active development, and at the moment the documentation is sparse. There are some examples to get you started, see below.

Note that there are two versions of `covidm` here. Version 1 is the relatively more "stable" version, and it is the version that all the examples currently use. Version 2 is under more active development, and can run quite a bit faster because it shifts more of the computation into C++ rather than keeping it in R, especially in the context of model fitting. However, we are still in the process of making this user-friendly.

This repository is for development of the model itself. Several projects which use `covidm` come bundled with their own version of it, and consulting the code for these projects may help illuminate how the model can be used. These projects include:
* [COVID-19 scenario projections for the UK](https://github.com/cmmid/covid-uk) (dating from late February to early March 2020)

## Installation for Windows 10

Before using covidm, you will need to have `Rcpp` set up and install the GNU Scientific Library. Instructions for how to do so follow.

1. Install R packages Rcpp and RcppGSL.
2. Install Rtools (https://cran.r-project.org/bin/windows/Rtools/).
3. Download a prebuilt GSL library by downloading `localXXX.zip` from http://www.stats.ox.ac.uk/pub/Rtools/goodies/multilib/. As of May 2nd 2020 the latest version was `local323.zip`. Download this file and unzip the contents to a folder of your choosing; for example, to `C:/Users/[YourUsername]/GSL`. The zip file contains two folders, `include` and `lib`; in the example folder, the full path to these two folders would be `C:/Users/[YourUsername]/GSL/include` and `C:/Users/[YourUsername]/GSL/lib`.
4. Go to `C:/Users/[YourUsername]`, and make the folder `.R` if it does not exist. (The dot at the start of the folder name is important.) Make a new plain text file (e.g. in Notepad), paste the two lines below making the appropriate changes as needed and save it as `C:/Users/[YourUsername]/.R/Makevars.win`.
```
PKG_CPPFLAGS=-I "C:/Users/[YourUsername]/GSL/include" -I../inst/include
PKG_LIBS=-L "C:/Users/[YourUsername]/GSL/lib/x64" -lgsl -lgslcblas
```
**Note: The path `C:/Users/[YourUsername]/GSL` in the two `Makevars.win` lines in step 4 should be the same path where you unzipped the include and lib directories as in step 3. The quotation marks around the paths in each line are needed if the paths contain spaces.**

### Troubleshooting on Windows
An alternative, non-preferred workaround to step 4 if the environment variables cannot be successfully changed when executing the R-scripts (possibly due to lack of admin rights) may be to manually copy and paste the folder `gsl` found in `C:/Users/[YourUsername]/GSL/include` into the sub-folder of the R package `RcppGSL` named `include` (e.g. at `.../R/library/RcppGSL/include`), and the files `libgsl.a` and `libgslcblas.a` found in `C:/Users/[YourUsername]/GSL/lib/x64` into the respective sub-folder in rtools named `mingw` (e.g for Rtools 4.0 the folder may be found at `C:/rtools40/mingw64/lib`). Note that Rtools 4.0 requires R 4.0.0 or newer. Also, if the R scripts already compiled successfully as intended after step 4, this workaround is not required.

## Installation for Mac OS X

You will need to install gfortran binaries from here: https://github.com/fxcoudert/gfortran-for-macOS/releases. 

Once installed, run `gcc --version` in terminal to get your current version, e.g. `Target: x86_64-apple-darwin18.8.2.0`. Then run below in terminal to add library path for R:

```
cd ~
mkdir .R
cd .R
nano Makevars
```
content

```
LOC = /usr/local/gfortran
CC=$(LOC)/bin/gcc -fopenmp
CXX=$(LOC)/bin/g++ -fopenmp
CXX11 = $(LOC)/bin/g++ -fopenmp # for fst package

CFLAGS=-g -O3 -Wall -pedantic -std=gnu99 -mtune=native -pipe
CXXFLAGS=-g -O3 -Wall -pedantic -std=c++11 -mtune=native -pipe
LDFLAGS=-L$(LOC)/lib -Wl,-rpath,$(LOC)/lib
CPPFLAGS=-I$(LOC)/include -I/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include
FLIBS=-L/usr/local/gfortran/lib/gcc/x86_64-apple-darwin18/8.2.0 -L/usr/local/gfortran/lib -lgfortran -lquadmath -lm
```
(see https://github.com/Rdatatable/data.table/wiki/Installation#openmp-enabled-compiler-for-mac "GCC (Official GNU fortran) ver". I'm not sure if FLIBS is needed) 

Some of the other R files use a lot of memory - it might help to do this:

```
nano ~/.Renviron 
```
contents
```
R_MAX_VSIZE=100Gb
```
(see https://stackoverflow.com/questions/51248293/error-vector-memory-exhausted-limit-reached-r-3-5-0-macos#52612848 )

## Installation on Ubuntu (Buster)

```
sudo apt-get update
sudo apt-get upgrade
sudo apt-get install cmake gfortran libnlopt-cxx-dev libgsl0-dev git r-base r-base-dev
git clone https://github.com/libbymiller/newcovid.git
cd newcovid/
sudo Rscript 0-install-packages.R
mkdir output
mkdir fits
git checkout 51c0b8a17a9a24e115d8b cpp_funcs.R
Rscript fit.R
```

## Examples

These can be found in the `examples` folder. This includes the following R files for version 1:

* `examples/0-libraries.R` - Install required R libraries
* `examples/v1/1-getting-started.R` - Compile code and run a basic simulation
* `examples/v1/2-interventions.R` - Run intervention scenarios
* `examples/v1/3-processes.R` - Set up an observation process (one way of calculating health burdens over time). 
* `examples/v1/4-fitting.R` - Fitting model to data using MCMC. 
* `examples/v1/5-observer.R` - Set up an observer to dynamically change parameters during a simulation. 

Model parameters are documented in `parameters_ref.txt`.


For example:

* `Rscript examples/0-libraries.R`
* `Rscript examples/v1/1-getting-started.R`


For Version 2:

* `examples/0-libraries.R` - Install required R libraries
* `examples/1-getting-started.R` - Compile code and run a basic simulation
* `examples/2-interventions.R` - Run intervention scenarios
* `examples/3-vaccination.R` - ??

For example:

* `Rscript examples/0-libraries.R`
* `Rscript examples/1-getting-started.R`
