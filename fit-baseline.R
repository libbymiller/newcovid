# fit-baseline: For pre-VOC fits.

library(data.table)
library(ggplot2)
library(lubridate)
library(here)
library(cowplot)
library(readxl)
library(sn)
library(qs)
library(stringr)
library(mgcv)
library(binom)

N_THREADS = 46
REP_START = 1
REP_END = 1
BURN_IN = 2000
BURN_IN_FINAL = 2000
ITER = 500

which_pops = c(1, 3, 4, 5, 6, 9, 10)
set_id = ""

# Command line
FIT_TYPE = commandArgs(trailingOnly = TRUE)[[1]];

if (FIT_TYPE == "a") {
    which_pops = c(1, 3, 4, 5)
    set_id = "a"
} else if (FIT_TYPE == "b") {
    which_pops = c(6, 9, 10)
    set_id = "b"
} else {
    stop("FIT_TYPE needed at command line (a or b)")
}

uk_covid_data_path = "./fitting_data/";
datapath = function(x) paste0(uk_covid_data_path, x)

#
# SETUP
#

# set up covidm
cm_path = "./covidm_for_fitting/";
cm_force_rebuild = F;
cm_build_verbose = T;
cm_version = 2;
source(paste0(cm_path, "/R/covidm.R"))
popUK = readRDS(datapath("popNHS.rds"));
matricesUK = readRDS(datapath("matricesNHS.rds"));

cm_populations = rbind(cm_populations[name != "United Kingdom"], popUK)
cm_matrices = c(cm_matrices, matricesUK)
source("./distribution_fit.R");
source("./spim_output.R");
source("./check_fit.R")


#
# DATA
#

nhs_regions = popUK[, unique(name)]
pct = function(x) as.numeric(str_replace_all(x, "%", "")) / 100

all_data = qread(datapath("processed-data-2021-01-01.qs"))
ld = all_data[[1]]
sitreps = all_data[[2]]
virus = all_data[[3]][!Data.source %like% "7a|7b|6a|6b"]
sero = all_data[[4]]
sgtf = all_data[[5]]



#
# FITTING
#

# NUMBER OF REGIONS TO FIT
N_REG = 12;

# Build parameters for NHS regions ###
params = cm_parameters_SEI3R(nhs_regions[1:N_REG], deterministic = T, 
                             date_start = "2020-01-01", 
                             date_end = "2020-11-23",
    dE  = cm_delay_gamma(2.5, 2.5, t_max = 15, t_step = 0.25)$p,
    dIp = cm_delay_gamma(2.5, 4.0, t_max = 15, t_step = 0.25)$p,
    dIs = cm_delay_gamma(2.5, 4.0, t_max = 15, t_step = 0.25)$p,
    dIa = cm_delay_gamma(5.0, 4.0, t_max = 15, t_step = 0.25)$p)
params = cm_split_matrices_ex_in(params, 15)

# Load age-varying symptomatic rate
covid_scenario = qread(datapath("2-linelist_both_fit_fIa0.5-rbzvih.qs"));
covu = unname(rep(colMeans(covid_scenario[,  5:12]), each = 2));
covy = unname(rep(colMeans(covid_scenario[, 13:20]), each = 2));

for (i in seq_along(params$pop)) {
    params$pop[[i]]$u = covu / mean(covu);
    params$pop[[i]]$u2 = covu / mean(covu);
    params$pop[[i]]$y = covy;
    params$pop[[i]]$y2 = covy;
}

# Health burden processes
source("./processes.R")
params$processes = burden_processes

# changes
schedule_all = readRDS(datapath("schedule3-2021-01-06.rds"));
schedule = list();
for (i in seq_along(schedule_all)) {
    if (schedule_all[[i]]$pops < N_REG) {
        schedule[[length(schedule) + 1]] = schedule_all[[i]]
    }
}

# Remove NAs
for (i in seq_along(schedule)) {
    for (j in seq_along(schedule[[i]]$values)) {
        if (any(is.na(schedule[[i]]$values[[j]]))) {
            schedule[[i]]$values[[j]] = ifelse(is.na(schedule[[i]]$values[[j]]), prev, schedule[[i]]$values[[j]])
        }
        prev = schedule[[i]]$values[[j]];
    }
}
params$schedule = schedule


#
# Individual fits
#

source("./cpp_funcs.R")

# Fitting
priorsI = list(
    tS = "U 0 60",
    u = "N 0.09 0.02 T 0.04 0.2",
    death_mean = "N 15 2 T 5 30",    # <<< co-cin
    hosp_admission = "N 8 1 T 4 20", # <<< co-cin
    icu_admission = "N 12.5 1 T 8 14", # <<< co-cin
    cfr_rlo = "N 0 0.1 T -2 2",
    cfr_rlo2 = "N 0 0.1 T -2 2",
    cfr_rlo3 = "N 0 0.1 T -2 2",
    hosp_rlo = "N 0 0.1 T -2 2", 
    icu_rlo = "N 0 0.1 T -2 2",
    icu_rlo2 = "N 0 0.1 T -2 2",
    contact_final = "N 1 0.1 T 0 1",
    contact_s0 = "E 0.1 0.1",
    contact_s1 = "E 0.1 0.1",
    concentration1 = "N 2 .3 T 2 10",
    concentration2 = "N 2 .2 T 2 10",
    concentration3 = "N 2 .1 T 2 10",
    sep_boost = "N 1 0.05",
    sep_when = "U 214 274",
    disp_deaths = "E 10 10",
    disp_hosp_inc = "E 10 10",
    disp_hosp_prev = "E 10 10",
    disp_icu_prev = "E 10 10"
)


posteriorsI = list()
dynamicsI = list()
parametersI = list()

# Remove problematic virus entries
virus = virus[omega > 1e-9]

existing_file = paste0("./fits/baseline", REP_START - 1, set_id, ".qs");
if (file.exists(existing_file)) {
    saved = qread(existing_file)
    posteriorsI = saved[[1]]
    parametersI = saved[[2]]
    rm(saved)
}

for (replic in REP_START:REP_END)
{
    init_previous = TRUE
    init_previous_amount = 1
    
    # RCB checking execution time to test multithreading
    time1 <- Sys.time()
    
    # Loop through regions
    for (p in which_pops) {
        paramsI = rlang::duplicate(params);
        paramsI$pop = list(rlang::duplicate(params$pop[[p]]));
        paramsI$travel = matrix(1, nrow = 1, ncol = 1);
        paramsI$schedule = list();
        j = 1;
        for (i in seq_along(params$schedule)) {
            if (p - 1 == params$schedule[[i]]$pops) {
                paramsI$schedule[[j]] = rlang::duplicate(params$schedule[[i]]);
                paramsI$schedule[[j]]$pops = 0;
                j = j + 1;
            }
        }
    
        # contact placeholder for tier 2
        paramsI$schedule[[2]] = rlang::duplicate(paramsI$schedule[[1]]);
        for (i in seq_along(paramsI$schedule[[2]]$values)) {
            paramsI$schedule[[2]]$values[[i]][1] = paramsI$schedule[[1]]$values[[i]][1] +  0.2497655 / 100;
            paramsI$schedule[[2]]$values[[i]][2] = paramsI$schedule[[1]]$values[[i]][2] + -0.2307939 / 100;
            paramsI$schedule[[2]]$values[[i]][3] = paramsI$schedule[[1]]$values[[i]][3] + -1.5907698 / 100;
            paramsI$schedule[[2]]$values[[i]][4] = paramsI$schedule[[1]]$values[[i]][4] + -3.4866544 / 100;
            paramsI$schedule[[2]]$values[[i]][5] = paramsI$schedule[[1]]$values[[i]][5] + -3.4524518 / 100;
        }
        paramsI$schedule[[2]]$mode = "bypass";
    
        # contact placeholder for tier 3
        paramsI$schedule[[3]] = rlang::duplicate(paramsI$schedule[[1]]);
        for (i in seq_along(paramsI$schedule[[3]]$values)) {
            paramsI$schedule[[3]]$values[[i]][1] = paramsI$schedule[[1]]$values[[i]][1] +  2.080457 / 100;
            paramsI$schedule[[3]]$values[[i]][2] = paramsI$schedule[[1]]$values[[i]][2] + -8.045226 / 100;
            paramsI$schedule[[3]]$values[[i]][3] = paramsI$schedule[[1]]$values[[i]][3] + -2.476266 / 100;
            paramsI$schedule[[3]]$values[[i]][4] = paramsI$schedule[[1]]$values[[i]][4] + -10.144043 / 100;
            paramsI$schedule[[3]]$values[[i]][5] = paramsI$schedule[[1]]$values[[i]][5] + -7.681244 / 100;
        }
        paramsI$schedule[[3]]$mode = "bypass";
    
        # contact multiplier for gradual contact change
        paramsI$schedule[[4]] = list(
            parameter = "contact",
            pops = 0,
            mode = "multiply",
            values = rep(list(rep(1, 8)), 366),
            times = 0:365
        )
    
        # contact multiplier for september boost
        paramsI$schedule[[5]] = list(
            parameter = "contact",
            pops = 0,
            mode = "multiply",
            values = list(rep(1, 8)),
            times = c(244)
        )
        
        ldI = rlang::duplicate(ld);
        ldI = ldI[pid == p - 1];
        sitrepsI = rlang::duplicate(sitreps);
        sitrepsI = sitrepsI[pid == p - 1];
        seroI = rlang::duplicate(sero);
        seroI = seroI[pid == p - 1 & Data.source != "NHSBT"];   # sero: all but NHSBT
        virusI = rlang::duplicate(virus);
        virusI = virusI[pid == p - 1 & Data.source %like% "REACT"]; # virus: REACT only
        sgtfI = copy(sgtf);
        sgtfI = sgtfI[pid == p - 1];
    
        # load user defined functions
        cm_source_backend(
            user_defined = list(
                model_v2 = list(
                    cpp_changes = cpp_chgI_voc(priorsI, v2 = FALSE, v2_relu = FALSE, v2_latdur = FALSE, v2_infdur = FALSE, v2_immesc = FALSE, v2_ch_u = FALSE),
                    cpp_loglikelihood = cpp_likI_voc(paramsI, ldI, sitrepsI, seroI, virusI, sgtfI, p, "2020-11-23", priorsI, death_cutoff = 0, use_sgtf = FALSE),
                    cpp_observer = cpp_obsI_voc(FALSE, P.death, P.critical, priorsI)
                )
            )
        )

        priorsI2 = rlang::duplicate(priorsI)
        if (init_previous) {
            for (k in seq_along(priorsI2)) {
                pname = names(priorsI2)[k];
                if (length(posteriorsI) >= p && pname %in% names(posteriorsI[[p]])) {
                    init_values = quantile(posteriorsI[[p]][[pname]], c(0.025, 0.975));
                    cat(paste0("Using 95% CI ", init_values[1], " - ", init_values[2], " for initial values of parameter ", pname, 
                        " with probability ", init_previous_amount, "\n"));
                    priorsI2[[pname]] = paste0(priorsI2[[pname]], " I ", init_values[1], " ", init_values[2], " ", init_previous_amount);
                    cat(paste0(priorsI2[[pname]], "\n"));
                } else {
                    cat(paste0("Could not find init values for parameter ", pname, "\n"));
                    cat(paste0(priorsI2[[pname]], "\n"));
                }
            }
        }
    
        postI = cm_backend_mcmc_test(cm_translate_parameters(paramsI), priorsI2,
            seed = 0, burn_in = ifelse(replic == REP_END, BURN_IN_FINAL, BURN_IN), 
            iterations = ITER, n_threads = N_THREADS, classic_gamma = T);
        setDT(postI)
        posteriorsI[[p]] = postI
    
        parametersI[[p]] = rlang::duplicate(paramsI)
        qsave(rlang::duplicate(list(posteriorsI, parametersI)), paste0("./fits/baseline", replic, set_id, "-progress.qs"))
    
        print(p)
    }
    
    # RCB timing check again
    time2 <- Sys.time()
    print(time2-time1)
    # 45 mins for England

    qsave(rlang::duplicate(list(posteriorsI, parametersI)), paste0("./fits/baseline", replic, set_id, ".qs"))
    
    # Generate SPI-M output
    # Sample dynamics from fit
    # load_fit("./fits/pp10.qs")
    dynamicsI = list()
    for (p in which_pops)  {
        cat(paste0("Sampling fit for population ", p, "...\n"))
        
        # Source backend
        cm_source_backend(
            user_defined = list(
                model_v2 = list(
                    cpp_changes = cpp_chgI_voc(priorsI, v2 = FALSE, v2_relu = FALSE, v2_latdur = FALSE, v2_infdur = FALSE, v2_immesc = FALSE, v2_ch_u = FALSE),
                    cpp_loglikelihood = "",
                    cpp_observer = cpp_obsI_voc(FALSE, P.death, P.critical, priorsI)
                )
            )
        )
        
        # Sampling fits
        paramsI2 = rlang::duplicate(parametersI[[p]])
        paramsI2$time1 = as.character(ymd(parametersI[[p]]$time1) + 56);
        test = cm_backend_sample_fit_test(cm_translate_parameters(paramsI2), posteriorsI[[p]], 100, seed = 0);
        rows = cm_backend_sample_fit_rows(cm_translate_parameters(paramsI2), posteriorsI[[p]], 100, seed = 0);
        
        test = rbindlist(test)
        test[, population := p]
        
        # Add dispersion parameters
        disp = posteriorsI[[p]][rows, .SD, .SDcols = patterns("^disp")]
        disp[, run := .I]
        test = merge(test, disp, by = "run")

        dynamicsI[[p]] = test
    }
    
    # Concatenate dynamics for SPI-M output
    test = rbindlist(dynamicsI, fill = TRUE)
    test[, population := nhs_regions[population]]

    # Visually inspect fit
    plot = check_fit(test, ld, sitreps, virus, sero, nhs_regions[which_pops], death_cutoff = 0, "2020-12-30")
    plot = plot + geom_vline(aes(xintercept = ymd("2020-11-23")), size = 0.25, linetype = "42")
    ggsave(paste0("./output/fit_baseline", replic, set_id, ".pdf"), plot, width = 40, height = 25, units = "cm", useDingbats = FALSE)
}
