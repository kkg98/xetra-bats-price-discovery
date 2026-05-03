# =============================================================================
# Cross-Atlantic Price Discovery: XETRA (EUR) vs BATS (USA, USD)
# Market Microstructures — WU Wien, Winter 2024
# Author: Katarina Gregusova
#
# Empirical application of the framework in:
#   Pascual, Pascual-Fuster & Climent (2006). "Cross-listing, price discovery
#   and the informativeness of the trading process."
#   Journal of Financial Markets, 9(2), 144–161.
#
# Six stocks dual-listed on XETRA (Frankfurt, EUR-quoted) and BATS (USA,
# USD-quoted), Oct 31 – Dec 9, 2024. 30-second OHLCV bars from TradingView.
# Analysis restricted to the US Open overlap session (14:30–21:00 UTC)
# where both venues trade simultaneously.
#
# Note on currency: the script does NOT convert prices to a common currency,
# so any test on price levels (mean deviation, Engle-Granger, Johansen,
# Granger on levels) implicitly absorbs the EUR/USD exchange rate. The
# log-return VAR analysis (Sections 9–10) is scale-invariant and is the
# primary result of the project.
#
# Pipeline:
#   0. Setup & package management
#   1. Load data & find common trading window
#   2. Align to 30-second grid, label trading sessions
#   3. Mean price deviations (XETRA − BATS) by session
#   4. ADF stationarity tests on price levels
#   5. Cointegration: Engle-Granger residual ADF + Johansen trace test
#   6. Granger causality (log prices, lag 5)
#   7. Scatter plots: XETRA vs BATS prices (US Open)
#   8. Smoothed time-series: prices and spread across full window
#   9. Log returns & VAR models (AIC lag selection)
#  10. Residual diagnostics: correlation and R² by venue
# =============================================================================


# 0. Setup --------------------------------------------------------------------

required_packages <- c(
  "dplyr", "lubridate", "ggplot2",
  "tseries",   # adf.test
  "lmtest",    # grangertest
  "vars",      # VAR, VARselect, vec2var
  "zoo",       # rollapply, na.locf
  "urca"       # ca.jo (Johansen)
)

missing_pkgs <- setdiff(required_packages, rownames(installed.packages()))
if (length(missing_pkgs) > 0) {
  install.packages(missing_pkgs, dependencies = TRUE)
}
invisible(lapply(required_packages, library, character.only = TRUE))

# Portable script-directory resolver: works under Rscript and RStudio
script_dir <- local({
  cmd_args  <- commandArgs(trailingOnly = FALSE)
  file_flag <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_flag) > 0) {
    dirname(normalizePath(sub("^--file=", "", file_flag)))
  } else {
    tryCatch(
      dirname(normalizePath(rstudioapi::getSourceEditorContext()$path)),
      error = function(e) getwd()
    )
  }
})

data_dir <- file.path(script_dir, "data")
fig_dir  <- file.path(script_dir, "figures")
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)

stopifnot(dir.exists(data_dir))   # halt early if data folder missing


# 1. Load Data & Common Window ------------------------------------------------

# Stock pair definitions: each entry maps a ticker label to its XETRA and BATS
# CSV filenames as stored in data/.
stock_pairs <- list(
  TL0  = c(xetra = "XETR_DLY_TL0, 30S.csv",    bats = "BATS_TSLA, 30S.csv"),
  MSF  = c(xetra = "XETR_DLY_MSF, 30S.csv",    bats = "BATS_MSFT, 30S.csv"),
  AMZ  = c(xetra = "XETR_DLY_AMZ, 30S-2.csv",  bats = "BATS_AMZN, 30S.csv"),
  SAP  = c(xetra = "XETR_DLY_SAP, 30S.csv",    bats = "BATS_SAP, 30S.csv"),
  NVD  = c(xetra = "XETR_DLY_NVD, 30S-2.csv",  bats = "BATS_NVDA, 30S.csv"),
  `2PP` = c(xetra = "XETR_DLY_2PP, 30S.csv",   bats = "BATS_PYPL, 30S.csv")
)

load_ohlcv <- function(filename) {
  path <- file.path(data_dir, filename)
  if (!file.exists(path)) stop("Data file not found: ", path)
  df <- read.csv(path, stringsAsFactors = FALSE)
  stopifnot("time" %in% colnames(df), "close" %in% colnames(df))
  # Parse ISO-8601 timestamps; convert to UTC so XETRA (+02:00) and
  # BATS (+01:00) timestamps align on the same scale.
  df$time <- ymd_hms(df$time, tz = "UTC")
  stopifnot(sum(!is.na(df$time)) > 0)
  df
}

all_files <- unique(unlist(stock_pairs))
raw_data  <- setNames(lapply(all_files, load_ohlcv), all_files)

# Find the maximum start time and minimum end time across all files —
# this is the window where every stock has continuous coverage.
time_ranges  <- lapply(raw_data, function(df) range(df$time, na.rm = TRUE))
common_start <- max(sapply(time_ranges, `[`, 1))
common_end   <- min(sapply(time_ranges, `[`, 2))
common_start <- as.POSIXct(common_start, tz = "UTC", origin = "1970-01-01")
common_end   <- as.POSIXct(common_end,   tz = "UTC", origin = "1970-01-01")

stopifnot(common_start < common_end)
cat(sprintf(
  "Common trading window: %s → %s  (%.0f calendar days)\n",
  format(common_start, tz = "UTC"),
  format(common_end,   tz = "UTC"),
  as.numeric(difftime(common_end, common_start, units = "days"))
))


# 2. Align to 30-Second Grid & Label Sessions ---------------------------------

# Build a complete 30-second timestamp grid covering the common window.
# Each stock's data is left-joined onto this grid so that missing bars become
# explicit NAs rather than silently absent rows.
time_grid <- seq(from = common_start, to = common_end, by = "30 secs")

align_to_grid <- function(df) {
  df_filtered <- df %>% filter(time >= common_start, time <= common_end)
  data.frame(time = time_grid) %>%
    left_join(df_filtered, by = "time")
}

aligned_data <- lapply(raw_data, align_to_grid)

# Session labels (all times in UTC):
#   European    07:00 – 12:00  XETRA open, BATS open, US closed
#   Pre-US Open 12:00 – 14:30  both European venues open, US pre-market
#   US Open     14:30 – 21:00  XETRA + BATS + NYSE/NASDAQ all open
#   (outside these windows rows are dropped in cleaned_data below)
label_session <- function(df) {
  df %>%
    mutate(
      hms     = format(time, "%H:%M:%S", tz = "UTC"),
      session = case_when(
        hms >= "07:00:00" & hms <  "12:00:00" ~ "European",
        hms >= "12:00:00" & hms <  "14:30:00" ~ "Pre-US Open",
        hms >= "14:30:00" & hms <= "21:00:00" ~ "US Open",
        TRUE ~ NA_character_
      )
    ) %>%
    dplyr::select(-hms)
}

labeled_data <- lapply(aligned_data, label_session)

# Drop bars outside any named session (overnight, weekends)
cleaned_data <- lapply(labeled_data, function(df) filter(df, !is.na(session)))

cat(sprintf(
  "US Open bars per file (sample — BATS TSLA): %d\n",
  sum(cleaned_data[["BATS_TSLA, 30S.csv"]]$session == "US Open", na.rm = TRUE)
))


# 3. Mean Price Deviations ----------------------------------------------------
# For each stock pair, compute mean(close_XETRA − close_BATS) per session.
# Only the US Open session has meaningful overlap; European and Pre-US Open
# values are NaN because BATS prices are missing outside US hours.

compute_deviations <- function(pair_name) {
  xetra_df <- cleaned_data[[stock_pairs[[pair_name]]["xetra"]]]
  bats_df  <- cleaned_data[[stock_pairs[[pair_name]]["bats"]]]

  merge(xetra_df, bats_df, by = "time", suffixes = c("_xetra", "_bats")) %>%
    mutate(price_dev = close_xetra - close_bats) %>%
    group_by(session = session_xetra) %>%
    summarise(
      mean_dev = mean(price_dev, na.rm = TRUE),
      sd_dev   = sd(price_dev,   na.rm = TRUE),
      n        = n(),
      .groups  = "drop"
    ) %>%
    mutate(stock = pair_name)
}

deviations    <- do.call(rbind, lapply(names(stock_pairs), compute_deviations))
us_open_devs  <- deviations %>% filter(session == "US Open")

cat("\nMean XETRA − BATS price deviations (US Open):\n")
print(us_open_devs[, c("stock", "mean_dev", "sd_dev", "n")])

p_deviations <- ggplot(us_open_devs, aes(x = stock, y = mean_dev, fill = stock)) +
  geom_col(colour = "black") +
  geom_errorbar(
    aes(ymin = mean_dev - sd_dev, ymax = mean_dev + sd_dev),
    width = 0.25, linewidth = 0.8
  ) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  scale_fill_brewer(palette = "Set3") +
  labs(
    title = "Mean XETRA − BATS Price Deviation (US Open Session)",
    subtitle = "Note: XETRA in EUR, BATS in USD — gap is FX-dominated, not a price-discovery signal",
    x     = "Stock",
    y     = "Mean price deviation (XETRA EUR − BATS USD)"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5), legend.position = "none")

ggsave(file.path(fig_dir, "mean_price_deviations.png"),
       p_deviations, width = 10, height = 5, dpi = 150)


# 4. Stationarity: ADF Tests --------------------------------------------------
# Augmented Dickey-Fuller test on closing price levels during the US Open
# session. Expectation: prices are I(1), so we expect to fail to reject H0
# (non-stationarity) for most series.

filter_us_open <- function(df) filter(df, session == "US Open")

run_adf_all <- function() {
  rows <- list()
  for (pair in names(stock_pairs)) {
    xetra_close <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["xetra"]]])$close)
    bats_close  <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["bats"]]])$close)

    stopifnot(length(xetra_close) > 20, length(bats_close) > 20)

    rows[[length(rows) + 1]] <- data.frame(
      stock   = pair,
      venue   = "XETRA",
      p_value = adf.test(xetra_close, alternative = "stationary")$p.value
    )
    rows[[length(rows) + 1]] <- data.frame(
      stock   = pair,
      venue   = "BATS",
      p_value = adf.test(bats_close, alternative = "stationary")$p.value
    )
  }
  do.call(rbind, rows)
}

adf_results <- run_adf_all()

cat("\nADF test results (H0: non-stationary):\n")
print(adf_results %>% mutate(conclusion = ifelse(p_value < 0.05, "Stationary", "Non-stationary")))

p_adf <- ggplot(adf_results, aes(x = stock, y = p_value, fill = venue)) +
  geom_col(position = "dodge", colour = "black") +
  geom_hline(yintercept = 0.05, linetype = "dashed", colour = "red") +
  annotate("text", x = 0.7, y = 0.06,
           label = "5% threshold", colour = "red", size = 3.5, hjust = 0) +
  scale_fill_manual(values = c(XETRA = "steelblue", BATS = "firebrick")) +
  labs(
    title = "ADF Test p-values — Price Levels (US Open Session)",
    x     = "Stock",
    y     = "p-value",
    fill  = "Venue"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5))

ggsave(file.path(fig_dir, "adf_tests.png"), p_adf, width = 10, height = 5, dpi = 150)


# 5. Cointegration ------------------------------------------------------------

# 5a. Engle-Granger two-step test:
#     (1) regress BATS on XETRA prices; (2) ADF test on residuals.
#     If residuals are stationary, the pair is cointegrated.

cat("\n=== Engle-Granger Cointegration Tests ===\n")
for (pair in names(stock_pairs)) {
  xetra_close <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["xetra"]]])$close)
  bats_close  <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["bats"]]])$close)
  n <- min(length(xetra_close), length(bats_close))

  if (n < 10) { cat(pair, ": insufficient data\n"); next }

  resids <- residuals(lm(bats_close[1:n] ~ xetra_close[1:n]))
  eg_p   <- adf.test(resids, alternative = "stationary")$p.value
  cat(sprintf("%-5s  ADF on residuals p = %.4f  →  %s\n",
              pair, eg_p,
              ifelse(eg_p < 0.05, "Cointegrated", "Not cointegrated")))
}

# 5b. Johansen trace test (urca::ca.jo)
# Note: the Johansen test consistently fails to reject H0 (r = 0) for these
# 30-second price series. This is methodologically expected — short-window
# intraday prices at 30-second frequency tend not to exhibit the
# mean-reverting behaviour the test is designed to detect. We document the
# result transparently and pivot to Granger causality and VAR on log returns,
# which are more appropriate for high-frequency data.

cat("\n=== Johansen Trace Tests ===\n")
for (pair in names(stock_pairs)) {
  cat("\n---", pair, "---\n")
  xetra_close <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["xetra"]]])$close)
  bats_close  <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["bats"]]])$close)
  n <- min(length(xetra_close), length(bats_close))

  if (n < 20) { cat("Insufficient data.\n"); next }

  combined_mat <- cbind(xetra_close[1:n], bats_close[1:n])
  colnames(combined_mat) <- c("XETRA", "BATS")

  jtest <- tryCatch(
    ca.jo(combined_mat, type = "trace", ecdet = "const", K = 2),
    error = function(e) { cat("Error:", e$message, "\n"); NULL }
  )
  if (is.null(jtest)) next

  # Column name varies by urca version ("5pct" or "5%"); use index 2 robustly
  cval_col <- colnames(jtest@cval)[2]
  for (i in seq_len(min(length(jtest@teststat), nrow(jtest@cval)))) {
    crit <- jtest@cval[i, cval_col]
    stat <- jtest@teststat[i]
    cat(sprintf(
      "  r ≤ %d:  stat = %6.2f,  5%% crit = %6.2f  →  %s\n",
      i - 1, stat, crit,
      ifelse(stat > crit, "Reject H0 (cointegrated)", "Fail to reject H0")
    ))
  }
}


# 6. Granger Causality --------------------------------------------------------
# Tests whether past XETRA prices help predict BATS prices and vice versa,
# at lag order 5 (= 2.5 minutes at 30-second frequency).

run_granger_all <- function(max_lag = 5) {
  rows <- list()
  for (pair in names(stock_pairs)) {
    xetra_close <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["xetra"]]])$close)
    bats_close  <- na.omit(filter_us_open(cleaned_data[[stock_pairs[[pair]]["bats"]]])$close)
    n <- min(length(xetra_close), length(bats_close))
    if (n <= max_lag) next

    combined_df <- data.frame(XETRA = xetra_close[1:n], BATS = bats_close[1:n])
    p_xb <- grangertest(BATS  ~ XETRA, order = max_lag, data = combined_df)$`Pr(>F)`[2]
    p_bx <- grangertest(XETRA ~ BATS,  order = max_lag, data = combined_df)$`Pr(>F)`[2]

    rows <- c(rows, list(
      data.frame(stock = pair, direction = "XETRA → BATS", p_value = p_xb),
      data.frame(stock = pair, direction = "BATS → XETRA",  p_value = p_bx)
    ))
  }
  do.call(rbind, rows)
}

granger_results <- run_granger_all()
granger_results$direction <- factor(
  granger_results$direction,
  levels = c("XETRA → BATS", "BATS → XETRA")
)

cat("\nGranger causality results:\n")
print(granger_results %>%
  mutate(significant = ifelse(p_value < 0.05, "Yes", "No")) %>%
  arrange(stock, direction))

p_granger <- ggplot(granger_results, aes(x = stock, y = -log10(p_value), fill = direction)) +
  geom_col(position = "dodge", colour = "black") +
  geom_hline(yintercept = -log10(0.05), linetype = "dashed", colour = "red") +
  annotate("text", x = 0.7, y = -log10(0.05) + 0.15,
           label = "5% threshold", colour = "red", size = 3.5, hjust = 0) +
  geom_text(
    aes(label = round(-log10(p_value), 1)),
    position = position_dodge(width = 0.9),
    vjust = -0.5, size = 3
  ) +
  scale_fill_manual(
    values = c("XETRA → BATS" = "steelblue", "BATS → XETRA" = "firebrick"),
    name   = "Direction"
  ) +
  expand_limits(y = max(-log10(granger_results$p_value), na.rm = TRUE) * 1.15) +
  labs(
    title = "Granger Causality: −log₁₀(p-value) at Lag 5",
    x     = "Stock",
    y     = "−log₁₀(p-value)"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5))

ggsave(file.path(fig_dir, "granger_causality.png"),
       p_granger, width = 10, height = 5, dpi = 150)


# 7. Scatter Plots: XETRA vs BATS Prices --------------------------------------

for (pair in names(stock_pairs)) {
  xetra_us <- filter_us_open(cleaned_data[[stock_pairs[[pair]]["xetra"]]])
  bats_us  <- filter_us_open(cleaned_data[[stock_pairs[[pair]]["bats"]]])

  scatter_df <- merge(xetra_us, bats_us, by = "time", suffixes = c("_xetra", "_bats")) %>%
    dplyr::select(time, close_xetra, close_bats)

  p_scatter <- ggplot(scatter_df, aes(x = close_xetra, y = close_bats)) +
    geom_point(alpha = 0.35, colour = "steelblue", size = 0.9) +
    geom_smooth(method = "lm", colour = "firebrick", se = TRUE, linewidth = 0.9) +
    labs(
      title = paste("XETRA vs BATS —", pair, "(US Open)"),
      x     = "XETRA close (EUR)",
      y     = "BATS close (USD)"
    ) +
    theme_minimal(base_size = 13) +
    theme(plot.title = element_text(hjust = 0.5))

  ggsave(file.path(fig_dir, paste0("scatter_", pair, ".png")),
         p_scatter, width = 6, height = 5, dpi = 150)
}


# 8. Smoothed Time-Series: Prices & Spread ------------------------------------
# 5-bar (2.5 min) centred rolling mean applied to both venue prices and the
# spread, then plotted across the full common window.

rolling_mean <- function(x, k = 5) {
  zoo::rollapply(x, k, mean, fill = NA, align = "center")
}

for (pair in names(stock_pairs)) {
  xetra_df <- cleaned_data[[stock_pairs[[pair]]["xetra"]]]
  bats_df  <- cleaned_data[[stock_pairs[[pair]]["bats"]]]

  ts_df <- merge(xetra_df, bats_df, by = "time", suffixes = c("_xetra", "_bats")) %>%
    mutate(
      smooth_xetra  = rolling_mean(close_xetra),
      smooth_bats   = rolling_mean(close_bats),
      smooth_spread = smooth_xetra - smooth_bats
    ) %>%
    filter(!is.na(smooth_xetra), !is.na(smooth_bats))

  p_ts <- ggplot(ts_df, aes(x = time)) +
    geom_line(aes(y = smooth_xetra,  colour = "XETRA"),  linewidth = 0.7) +
    geom_line(aes(y = smooth_bats,   colour = "BATS"),   linewidth = 0.7) +
    geom_line(aes(y = smooth_spread, colour = "Spread"), linewidth = 0.7, linetype = "dashed") +
    scale_x_datetime(date_breaks = "1 day", date_labels = "%b %d") +
    scale_colour_manual(
      values = c(XETRA = "steelblue", BATS = "firebrick", Spread = "seagreen3"),
      name   = NULL
    ) +
    labs(
      title = paste("Smoothed Prices & Spread —", pair),
      subtitle = "XETRA in EUR, BATS in USD",
      x     = NULL,
      y     = "Price (native currency)"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      axis.text.x     = element_text(angle = 45, hjust = 1),
      plot.title      = element_text(hjust = 0.5),
      legend.position = "top"
    )

  ggsave(file.path(fig_dir, paste0("timeseries_", pair, ".png")),
         p_ts, width = 12, height = 5, dpi = 150)
}


# 9. Log Returns & VAR Models -------------------------------------------------
# First-differences of log prices are stationary; VAR on log returns avoids the
# non-stationarity issue identified in Section 4.

compute_log_returns <- function(df) {
  df %>%
    filter(session == "US Open") %>%
    arrange(time) %>%
    mutate(log_ret = log(close / lag(close))) %>%
    drop_na(log_ret)
}

log_returns <- lapply(cleaned_data, compute_log_returns)

merge_log_returns <- function(pair) {
  xetra_lr <- log_returns[[stock_pairs[[pair]]["xetra"]]] %>%
    dplyr::select(time, log_return_xetra = log_ret)
  bats_lr  <- log_returns[[stock_pairs[[pair]]["bats"]]] %>%
    dplyr::select(time, log_return_bats = log_ret)
  merge(xetra_lr, bats_lr, by = "time", all = FALSE)
}

log_return_pairs <- setNames(
  lapply(names(stock_pairs), merge_log_returns),
  names(stock_pairs)
)

fit_var_aic <- function(pair, data) {
  cat("\n=== VAR (AIC lag selection):", pair, "===\n")
  var_data <- data %>% dplyr::select(log_return_xetra, log_return_bats)
  if (nrow(var_data) < 20) { cat("Insufficient data.\n"); return(NULL) }

  optimal_lag <- VARselect(var_data, lag.max = 10, type = "const")$selection["AIC(n)"]
  cat("Optimal lag (AIC):", optimal_lag, "\n")

  VAR(var_data, p = optimal_lag, type = "const")
}

var_models <- setNames(
  lapply(names(log_return_pairs), function(p) fit_var_aic(p, log_return_pairs[[p]])),
  names(log_return_pairs)
)

cat("\n=== VAR Summaries ===\n")
for (pair in names(var_models)) {
  if (!is.null(var_models[[pair]])) {
    cat("\n---", pair, "---\n")
    print(summary(var_models[[pair]]))
  }
}


# 10. Residual Diagnostics ----------------------------------------------------

# Correlation between XETRA and BATS VAR residuals.
# Computed directly from residuals() to avoid version-dependent covres structure.
residual_corr <- do.call(rbind, lapply(names(var_models), function(pair) {
  mdl <- var_models[[pair]]
  if (is.null(mdl)) return(NULL)
  cor_val <- cor(residuals(mdl))["log_return_xetra", "log_return_bats"]
  data.frame(stock = pair, residual_correlation = cor_val)
}))

cat("\nVAR residual correlations (XETRA vs BATS):\n")
print(residual_corr)

p_rescorr <- ggplot(residual_corr, aes(x = stock, y = residual_correlation, fill = stock)) +
  geom_col(colour = "black") +
  scale_fill_brewer(palette = "Set3") +
  scale_y_continuous(limits = c(0, 1)) +
  labs(
    title = "VAR Residual Correlation: XETRA vs BATS (US Open)",
    x     = "Stock",
    y     = "Residual correlation"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5), legend.position = "none")

ggsave(file.path(fig_dir, "residual_correlations.png"),
       p_rescorr, width = 8, height = 5, dpi = 150)

# R-squared: how much past cross-venue returns explain current returns
r_squared <- do.call(rbind, lapply(names(var_models), function(pair) {
  mdl <- var_models[[pair]]
  if (is.null(mdl)) return(NULL)
  rbind(
    data.frame(
      stock     = pair,
      venue     = "XETRA",
      r_squared = summary(mdl$varresult$log_return_xetra)$r.squared
    ),
    data.frame(
      stock     = pair,
      venue     = "BATS",
      r_squared = summary(mdl$varresult$log_return_bats)$r.squared
    )
  )
}))

cat("\nVAR R-squared by venue:\n")
print(r_squared)

p_rsq <- ggplot(r_squared, aes(x = stock, y = r_squared, fill = venue)) +
  geom_col(position = position_dodge(width = 0.7), colour = "black") +
  scale_fill_manual(values = c(XETRA = "steelblue", BATS = "firebrick")) +
  labs(
    title = "VAR Model R² by Venue (US Open Log Returns)",
    x     = "Stock",
    y     = "R²",
    fill  = "Venue"
  ) +
  theme_minimal(base_size = 13) +
  theme(plot.title = element_text(hjust = 0.5))

ggsave(file.path(fig_dir, "r_squared_comparison.png"),
       p_rsq, width = 9, height = 5, dpi = 150)

cat("\nDone. All figures saved to:", fig_dir, "\n")
