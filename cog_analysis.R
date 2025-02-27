library(ggplot2)
library(data.table)
library(zoo)
library(ogwrangler)
library(lubridate)
library(aod)
library(binom)
library(mgcv)
CreateCache()

# ONS Postcode Directory
onspd = fread("~/Downloads/ONSPD_AUG_2020_UK/Data/ONSPD_AUG_2020_UK.csv");
onspd = onspd[is.na(doterm), .(pcd, nhser, oslaua, lat, long)]
setkey(onspd, lat, long)

# Find ONSPD entry closest to a given latitude and longitude.
latlon = function(latitude, longitude, tol = 1)
{
    onspd2 = onspd[lat %between% c(latitude - tol, latitude + tol) & long %between% c(longitude - tol, longitude + tol)];
    onspd2[, dist := (lat - latitude)^2 + (long - longitude)^2];
    return (onspd2[which.min(dist)])
}

variance_beta = function(a, b) (a * b) / ((a + b)^2 * (a + b + 1))
mean_beta = function(a, b) a / (a + b)
variance_betas = function(w, a, b) sum(w^2 * mapply(variance_beta, a, b))
mean_betas = function(w, a, b) sum(w * mapply(mean_beta, a, b))

# mode of a beta dist
beta_mode = function(a, b)
{
    ifelse(a > 1 & b > 1, (a - 1) / (a + b - 2),
        ifelse(a < b, 0, 1))
}

# For identifying HDI of a beta distribution, when mode is not 0 or 1
p_range_beta = function(d, a, b)
{
    min = uniroot(function(x) dbeta(x, a, b) - d, lower = 0, upper = mode)$root;
    max = uniroot(function(x) dbeta(x, a, b) - d, lower = mode, upper = 1)$root;
    
    # return probability between min and max
    pbeta(max, a, b) - pbeta(min, a, b)
}

# Identify HDI of a beta distribution, when mode is not 0 or 1
beta_hdi_find = function(m, a, b)
{
    mode = beta_mode(a, b);
    if (mode == 0 || mode == 1)
        stop("beta distribution must have 0 < mode < 1.")
    peak = dbeta(mode, a, b);

    d = log(uniroot(function(x) p_range_beta(x, a, b) - m, lower = 0, upper = peak)$root);

    min = uniroot(function(x) dbeta(x, a, b, log = TRUE) - d, lower = 0, upper = mode)$root;
    max = uniroot(function(x) dbeta(x, a, b, log = TRUE) - d, lower = mode, upper = 1)$root;

    return (c(min = min, max = max))
}

# HDI of a beta dist
beta_hdi = function(a, b, m = 0.95)
{
    if (a == 1 && b == 1) {
        return (c(0.5 - m/2, 0.5 + m/2))
    }
    
    mode = beta_mode(a, b)
    
    if (mode == 0) {
        min = 0;
        max = qbeta(m, a, b);
    } else if (mode == 1) {
        min = qbeta(1 - m, a, b);
        max = 1;
    } else {
        return (beta_hdi_find(m, a, b))
    }
    
    return (c(min = min, max = max))
}

# Approximate weighted mean of several beta distributions
approx_mean_betas = function(w, a, b)
{
    mean = mean_betas(w, a, b);
    variance = variance_betas(w, a, b);
    alpha = mean * ((mean * (1 - mean)) / variance - 1)
    beta = (1 - mean) * ((mean * (1 - mean)) / variance - 1)
    return (c(shape1 = alpha, shape2 = beta))
}

# Get new lineage data
nl = function()
{
    #newlin = fread("./data/cog_metadata_microreact_public-2020-12-18.csv")
    #newlin = fread("./data/cog_metadata_microreact_public-2020-12-22.csv")
    #newlin = fread("./data/cog_metadata_microreact_public-2020-12-27.csv")
    newlin = fread("./data/cog_metadata_microreact_public-2020-12-29.csv")
    newlin = newlin[country == "UK"]
    newlin[, site := .GRP, by = .(longitude, latitude)]
    newlin[, B117 := lineage == "B.1.1.7"]
    newlin[, N_B117 := sum(B117), by = site]
    newlin[, var2 := B117 & n501y == "Y"]
    newlin[, N_var2 := sum(var2), by = site]
    newlin[, spec := paste0(d614g, n439k, p323l, a222v, y453f, n501y, del_21765_6)]
    
    # Assign localities
    sites = newlin[, unique(site)]
    for (s in sites) {
        cat(".");
        latitude = newlin[site == s, latitude[1]];
        longitude = newlin[site == s, longitude[1]];
        loc = latlon(latitude, longitude);
        if (nrow(loc) > 0) {
            newlin[site == s, pcd := loc$pcd];
            newlin[site == s, lad := loc$oslaua];
            newlin[site == s, nhs := loc$nhser];
        }
    }
    
    # Omit Gibraltar and unknown sites
    newlin = newlin[!is.na(nhs)]
    
    # NHS regions
    newlin[nhs %like% "E", nhs_name := ogwhat(nhs)]
    newlin[nhs %like% "N", nhs_name := "Northern Ireland"]
    newlin[nhs %like% "S", nhs_name := "Scotland"]
    newlin[nhs %like% "W", nhs_name := "Wales"]
    
    # Reassign site id to remove missing sites
    newlin[, site := .GRP, by = .(longitude, latitude)]
    
    return (newlin[])
}

newlin = nl()
#fwrite(newlin, "./data/cog_metadata_microreact_public-2020-12-29-annotated.csv");

# View sites
ggplot(unique(newlin[, .(latitude, longitude, nhs_name)])) + 
    geom_point(aes(x = longitude, y = latitude, colour = nhs_name))

# Build site-frequency-corrected variant frequency table
sitefreq = newlin[, .N, by = .(nhs_name, site)]
sitefreq[, freq := N / sum(N), by = .(nhs_name)]
date_min = newlin[, min(sample_date)]
date_max = newlin[, max(sample_date)]
ndate = as.numeric(date_max - date_min) + 1
nsite = sitefreq[, uniqueN(site)]
prior_a = 0.5
prior_b = 0.5

varfreq = data.table(site = rep(1:nsite, each = ndate))
varfreq[, date := rep(date_min + (0:(ndate - 1)), nsite)]
varfreq = merge(varfreq, 
    newlin[, .(var1 = sum(!var2), var2 = sum(var2)), keyby = .(date = sample_date, site)],
    by = c("date", "site"), all = TRUE)
varfreq[is.na(var1), var1 := 0]
varfreq[is.na(var2), var2 := 0]
varfreq = merge(varfreq, sitefreq[, .(site, nhs_name, sitefreq = freq)], by = "site")

# Find cutoff point
ggplot(varfreq[, sum(var1 > 0 | var2 > 0) / .N, by = .(date, nhs_name)]) + 
    geom_line(aes(date, V1, colour = nhs_name)) +
    geom_vline(aes(xintercept = ymd("2020-11-25"))) +
    facet_wrap(~nhs_name)

# Stain-glass plot
data_site = newlin[, .(all = .N, var2 = sum(var2)), keyby = .(site, sample_date, nhs_name)]
data_site[, site2 := as.numeric(match(site, unique(site))), by = nhs_name]
data_site[, site2 := site2 / max(site2), by = nhs_name]
ggplot(data_site[sample_date > "2020-10-01"]) +
    geom_col(aes(x = sample_date, y = all, fill = site2), colour = "black", size = 0.2, position = "fill") +
    facet_wrap(~nhs_name) +
    theme(legend.position = "none") +
    scale_fill_gradientn(colours = c("red", "yellow", "green", "blue", "violet")) +
    geom_vline(aes(xintercept = ymd("2020-12-15"))) +
    labs(x = "Sample date", y = "Proportion of COG-UK samples from each site")


ggplot(varfreq[, sum(var1 + var2), by = .(date, nhs_name)]) + 
    geom_line(aes(date, V1, colour = nhs_name)) +
    geom_vline(aes(xintercept = ymd("2020-11-25"))) +
    facet_wrap(~nhs_name, scales = "free")

v = varfreq[, .(var1 = sum(var1 * sitefreq) + 1, var2 = sum(var2 * sitefreq) + 0.5), by = .(nhs_name, date)]

for (i in 1:nrow(v)) {
    a = v[i, var2] # inverted because we are interested
    b = v[i, var1] # in the frequency of variant 2
    v[i, q_lo := qbeta(0.025, a, b)]
    v[i, q_hi := qbeta(0.975, a, b)]
    v[i, mode := beta_mode(v[i, var2], v[i, var1])];
}

ggplot(v) +
    geom_ribbon(aes(x = date, ymin = q_lo, ymax = q_hi), alpha = 0.2) +
    geom_line(aes(x = date, y = mode), alpha = 0.5) +
    facet_wrap(~nhs_name) + scale_y_log10()

# Make COG data
data = newlin[, .(all = .N, var2 = sum(var2)), keyby = .(sample_date, nhs_name)]
ggplot(data[sample_date <= "2020-12-31"]) +
    geom_line(aes(x = sample_date, y = var2 / all, colour = nhs_name)) +
    facet_wrap(~nhs_name) +
    theme(legend.position = "none")

#fwrite(data[sample_date <= "2020-12-01"], "./fitting_data/var2-2020-12-16.csv")
fwrite(data, "./fitting_data/var2-2020-12-21.csv")

data_site = newlin[, .(all = .N, var2 = sum(var2)), keyby = .(site, sample_date)]
data_site
ggplot(data_site) +
    geom_line(aes(x = sample_date, y = var2 / all, colour = site)) +
    facet_wrap(~site) +
    theme(legend.position = "none") +
    geom_vline(aes(xintercept = ymd("2020-12-01")))


raw = newlin[, .(var2 = sum(var2), all = .N, nsite = uniqueN(site)), by = .(sample_date, nhs_name)]
raw = raw[order(nhs_name, sample_date)]
raw[, fn := all / max(all), by = nhs_name]
raw[, fnr := rollmean(fn, 7, fill = NA), by = nhs_name]
raw[, fsite := nsite / max(nsite), by = nhs_name]
raw[, c("mean", "lower", "upper") := binom.confint(var2, all, method = "exact")[, 4:6]]

raw22 = copy(raw)
raw18 = copy(raw)

for (nhs in raw[, unique(nhs_name)])
{
    model = glm(cbind(var2, all - var2) ~ sample_date, family = "binomial", data = raw[nhs_name == nhs])
    raw[nhs_name == nhs, predicted := predict(model, newdata = .SD, type = "response")]
    print(nhs)
    print(model$coefficients[[2]])
}

library(aod)
model = betabin(cbind(var2, all - var2) ~ sample_date + nhs_name, ~ 1, data = raw[!nhs_name %in% c("Wales", "Northern Ireland", "Scotland")])
predicted2 = predict(model, newdata = raw[!nhs_name %in% c("Wales", "Northern Ireland", "Scotland")])
raw[!nhs_name %in% c("Wales", "Northern Ireland", "Scotland"), predicted2 := ..predicted2]

ggplot(raw[sample_date >= "2020-10-01"]) +
    geom_ribbon(aes(sample_date, ymin = lower, ymax = upper), fill = "darkorchid", alpha = 0.4) +
    geom_line(aes(sample_date, var2/all), colour = "darkorchid") +
    geom_line(aes(sample_date, predicted), colour = "black") +
    geom_line(aes(sample_date, predicted2), colour = "black", linetype = "dashed") +
    geom_step(aes(sample_date, fnr), colour = "black", size = 0.2) +
    facet_wrap(~nhs_name) +
    labs(x = "Sample date", y = "Number of samples (black, 7 day rolling mean);\nFrequency of VOC 202012/01 (purple)") +
    geom_vline(aes(xintercept = ymd("2020-12-15")))

ggsave("~/Documents/newcovid/output/raw-data-2020-12-22.pdf", width = 30, height = 20, units = "cm", useDingbats = FALSE)


w = merge(raw22[, .(f22 = var2/all, sample_date, nhs_name)], raw18[, .(f18 = var2/all, sample_date, nhs_name)], all = TRUE)
w[is.na(f22), f22 := 0]
w[is.na(f18), f18 := 0]
ggplot(w) +
    geom_line(aes(sample_date, f22 - f18), colour = "black") +
    facet_wrap(~nhs_name) +
    labs(x = "Sample date", y = "Change in frequency of VOC 202012/01\nin data from 22 Dec relative to 18 Dec")

ggsave("~/Documents/newcovid/output/raw-data-change.pdf", width = 30, height = 20, units = "cm", useDingbats = FALSE)

ggplot() +
    geom_line(data = raw18[sample_date >= "2020-10-01"], aes(sample_date, var2/all), colour = "black") +
    geom_line(data = raw22[sample_date >= "2020-10-01"], aes(sample_date, var2/all), colour = "darkorchid") +
    facet_wrap(~nhs_name) +
    labs(x = "Sample date", y = "Frequency of VOC 202012/01\ndata to 18 Dec (black) vs. data to 22 Dec (purple)")


raw22[, region := ifelse(nhs_name %in% c("East of England", "South East", "London"), "East of England,\nLondon, South East", "Rest of UK")]
ww = raw22[, .(var2 = sum(var2), all = sum(all)), keyby = .(sample_date, region)]

ggplot(ww[sample_date >= "2020-09-01"]) +
    geom_line(aes(x = sample_date, y = var2 / all, colour = region)) +
    scale_y_continuous(trans = scales::logit_trans(), breaks = c(0.001, 0.01, 0.1, 0.2, 0.4, 0.6, 0.8)) +
    labs(x = "Sample date", y = "Frequency of VOC 202012/01")

summary(glm(cbind(var2, all) ~ sample_date, 
    data = ww[region != "Rest of UK" & sample_date >= "2020-09-01"],
    family = "binomial"))
summary(glm(cbind(var2, all) ~ sample_date, 
    data = ww[region == "Rest of UK" & sample_date >= "2020-09-01"],
    family = "binomial"))



newlin[, fullspec := paste(lineage, spec, sep = "/")]
weekly = newlin[nhs_name == "Wales", .(k = .N), keyby = .(week(sample_date), fullspec)]
weekly[, N := sum(k), by = week]

ggplot(weekly) +
    geom_col(aes(x = week, y = k/N, fill = fullspec), colour = "black", position = "stack") +
    theme(legend.position = "none")

weekly_m1 = newlin[, .(prevk = .N), keyby = .(week = week(sample_date) + 1, fullspec)]
weekly_m1[, prevN := sum(prevk), by = week]
weekly = merge(weekly, weekly_m1)

ggplot(weekly) +
    geom_jitter(aes(x = week, y = log((k/N)/(prevk/prevN)), colour = fullspec == "B.1.1.7/GNLAYYdel"))

ww = weekly[, .(median(log((k/N)/(prevk/prevN))), sd(log((k/N)/(prevk/prevN))), .N), by = fullspec]
View(ww[order(V1)])
newlin[, fullspec]




# . . .

sep = fread(
"nhs_name,sep_boost,sep_when
East of England,1.286060,225.8318
England,NA,NA
London,1.150410,224.4728
Midlands,1.246579,229.1717
North East and Yorkshire,1.243735,226.6173
North West,1.149471,224.6648
Northern Ireland,1.096731,234.6402
Scotland,1.108947,248.0260
South East,1.171521,225.5470
South West,1.310023,253.8089
United Kingdom,NA,NA
Wales,1.365682,227.7810")

ggplot(newlin[, .(.N, sum(lineage == "B.1.177")), keyby = .(nhs_name, sample_date)]) + 
    geom_line(aes(x = sample_date, y = V2 / N)) + 
    geom_point(data = sep, aes(x = ymd("2020-01-01") + sep_when, y = sep_boost - 1), colour = "red") +
    facet_wrap(~nhs_name)



# 20A.EU1
newlin[, var20A.EU1 := lineage %like% "B\\.1\\.177"]
ggplot(newlin[, .(.N, sum(var20A.EU1 == TRUE)), keyby = .(nhs_name, sample_date)]) + 
    geom_line(aes(x = sample_date, y = V2 / N)) + 
    facet_wrap(~nhs_name)

ae = newlin[, .(N_ae = sum(var20A.EU1 == TRUE), N_other = sum(var20A.EU1 == FALSE)), keyby = .(nhs_name, sample_date)]
ae[, nhs_name := factor(nhs_name)]
ae[, sample_t := as.numeric(as.Date(sample_date) - ymd("2020-01-01"))]

model_ae = gam(cbind(N_ae, N_other) ~ s(sample_t, by = nhs_name), data = ae[sample_date > "2020-04-01"], family = "binomial")
plot(model_ae)

predict_ae = data.table(sample_t = rep(90:365, 10), nhs_name = rep(ae[, unique(nhs_name)], each = 276))
predict_ae[, f_ae := predict(model_ae, newdata = .SD, type = "response")]

ggplot(predict_ae) +
    geom_line(aes(x = sample_t + ymd("2020-01-01"), y = f_ae, colour = nhs_name))


ggplot(newlin[, .(.N), keyby = .(uk_lineage, sample_date)]) +
    geom_area(aes(x = sample_date, y = N, fill = uk_lineage), position = "fill")
