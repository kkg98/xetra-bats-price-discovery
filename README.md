# Cross-Exchange Price Discovery: XETRA vs BATS Europe

Empirical application of Pascual, Pascual-Fuster & Climent (2006), *"Cross-listing, price discovery and the informativeness of the trading process,"* Journal of Financial Markets, 9(2), 144–161.

---

## What the paper asks

When the same stock trades on two markets simultaneously — say, Tesla on Frankfurt's XETRA and on BATS Europe — which venue leads price discovery? Does the European exchange set the price that the other venue follows, or does information flow the other way?

Pascual et al. build on Hasbrouck's (1995) information-share framework to separate two sources of cross-market information asymmetry: shocks that originate *from trading* (informed investors choosing where to execute) and shocks that are *trade-unrelated* (public news, macro announcements). Their empirical counterpart is a Vector Error Correction model that explicitly identifies the unexpected, informative component of each venue's order flow.

The key insight is that a market can have high quoting activity and still contribute nothing to price discovery — what matters is whether its *trades* carry information. A pure satellite market has an uninformative trading process: prices there adjust to the dominant venue rather than the other way around.

> "A pure satellite market has an uninformative trading process that cannot shed light on the interpretation of public information."
> — Pascual, Pascual-Fuster & Climent (2006), p. 146

---

## What this project does

- Loads 30-second OHLCV bars from XETRA and BATS Europe for six dual-listed stocks (Tesla/TL0, Microsoft/MSF, Amazon/AMZ, SAP, NVIDIA/NVD, PayPal/2PP) over a one-month window (November–December 2024).
- Finds the common trading window across all 12 data files and aligns each series to a complete 30-second timestamp grid.
- Labels bars by trading session: European-only (07:00–12:00 UTC), Pre-US Open (12:00–14:30 UTC), and US Open (14:30–21:00 UTC). Analysis is restricted to the US Open overlap where both venues trade simultaneously.
- Computes mean price deviations (XETRA − BATS) per session with error bars.
- Runs ADF stationarity tests on price levels to confirm prices are I(1).
- Tests for cointegration via Engle-Granger (residual ADF) and Johansen trace test, and documents the results honestly — including that Johansen fails to reject H₀ at standard lags for this data.
- Runs Granger causality tests (lag 5 = 2.5 minutes) in both directions for all six pairs.
- Produces scatter plots and smoothed time-series plots of prices and spreads across the full window.
- Fits VAR models (AIC lag selection) on log returns and reports residual correlations and R² by venue.

---

## Results

### Mean price deviations (US Open session)

![Mean price deviations](figures/mean_price_deviations.png)

All deviations are negative during the US Open: XETRA prices are systematically below BATS prices for all six stocks, ranging from −4.7 EUR (PayPal) to −22.4 EUR (Microsoft). The magnitudes reflect absolute price-level differences between the two venues rather than a pure arbitrage signal — both platforms price the same underlying in EUR, but at slightly different levels, consistent with fragmented liquidity and asynchronous quote updates across venues.

### ADF stationarity tests

![ADF tests](figures/adf_tests.png)

Price levels are non-stationary (high p-values, fail to reject H₀) for all stocks on both venues — confirming I(1) behavior as expected. The analysis then proceeds on log returns.

### Granger causality

![Granger causality](figures/granger_causality.png)

Key findings at lag 5 (= 2.5 minutes, tested on price levels):

| Stock | XETRA → BATS | BATS → XETRA | Interpretation |
|-------|:---:|:---:|----------------|
| MSF (Microsoft) | ✓ p = 0.029 | ✓ p = 0.007 | Bidirectional |
| TL0, NVD, SAP, AMZ, 2PP | — | — | No significant lead |

Microsoft is the only pair with detectable Granger causality at the 5% level, and it runs in both directions — price movements on either venue carry predictive information for the other over a 2.5-minute horizon. The remaining five stocks show no significant lead-lag relationship at this frequency when tested on price levels.

Note: Granger causality on I(1) price levels can be unreliable. The VAR analysis in Section 9, run on stationary log returns, provides a more granular picture: SAP's BATS return equation shows strong XETRA predictors across multiple lags (R² = 0.054 vs 0.009 for the XETRA equation), and for NVD and TL0 the XETRA equation is substantially more predictable from past cross-venue returns than the BATS equation.

### Scatter plots — XETRA vs BATS prices

| TL0 | NVD | SAP |
|:---:|:---:|:---:|
| ![](figures/scatter_TL0.png) | ![](figures/scatter_NVD.png) | ![](figures/scatter_SAP.png) |

Strong linear co-movement during the US Open session across all pairs, consistent with the two venues pricing the same fundamental value.

### Smoothed time series

| TL0 | SAP |
|:---:|:---:|
| ![](figures/timeseries_TL0.png) | ![](figures/timeseries_SAP.png) |

The dashed green line is the XETRA − BATS spread. Spreads widen around market open and during high-volatility periods, then revert — consistent with transient information asymmetry between venues.

### VAR residual correlations

![Residual correlations](figures/residual_correlations.png)

Residual correlations range from ~0.64 (PayPal) to ~0.82 (Tesla, NVIDIA), reflecting how tightly the two venues co-move after controlling for lagged returns. Higher correlation indicates more synchronised order flow.

---

## Methodology

The analysis follows a two-stage approach grounded in Pascual et al.'s framework.

**Stage 1 — price levels.** XETRA and BATS closing prices are modelled as I(1) processes. The Engle-Granger two-step test regresses BATS prices on XETRA prices and applies an ADF test to the residuals; stationary residuals indicate cointegration. The Johansen trace test provides a multivariate complement. For 30-second intraday series over a one-month window, the Johansen test fails to reject H₀ (no cointegration) for all six pairs. The Engle-Granger test finds evidence of cointegration for Microsoft (p = 0.022) but not for the other five stocks. These results are consistent with the short observation period and the dominance of microstructure noise at high frequency, which tends to obscure mean-reversion dynamics.

**Stage 2 — log returns.** The VAR is estimated on log returns Δlog(P), which are stationary by construction:

$$\Delta \log P_t = \sum_{k=1}^{p} A_k \, \Delta \log P_{t-k} + \varepsilon_t$$

where $P_t = (\text{XETRA}_t, \text{BATS}_t)'$, $A_k$ are $2 \times 2$ coefficient matrices, and $\varepsilon_t$ is the residual vector. The lag order $p$ is selected by AIC (search over $p = 1, \ldots, 10$). Granger causality is tested via an F-test on the null that all lags of one venue's returns have zero coefficients in the other venue's equation.

---

## Reproducing the results

**Requirements:** R ≥ 4.2. The script installs any missing packages automatically on first run.

```bash
Rscript xetra_bats_price_discovery.R
```

Or open `xetra_bats_price_discovery.R` in RStudio and click **Source**.

All figures are saved to `figures/` and all numeric results are printed to the console.

**Packages used:** `dplyr`, `lubridate`, `ggplot2`, `tseries`, `lmtest`, `vars`, `zoo`, `urca`.

---

## Repository layout

```
xetra-bats-price-discovery/
├── xetra_bats_price_discovery.R   # single end-to-end script
├── README.md
├── .gitignore
├── data/                          # 30-second OHLCV bars (committed)
│   ├── BATS_AMZN, 30S.csv
│   ├── BATS_MSFT, 30S.csv
│   ├── BATS_NVDA, 30S.csv
│   ├── BATS_PYPL, 30S.csv
│   ├── BATS_SAP, 30S.csv
│   ├── BATS_TSLA, 30S.csv
│   ├── XETR_DLY_2PP, 30S.csv
│   ├── XETR_DLY_AMZ, 30S-2.csv
│   ├── XETR_DLY_MSF, 30S.csv
│   ├── XETR_DLY_NVD, 30S-2.csv
│   ├── XETR_DLY_SAP, 30S.csv
│   └── XETR_DLY_TL0, 30S.csv
└── figures/                       # produced by the script
    ├── mean_price_deviations.png
    ├── adf_tests.png
    ├── granger_causality.png
    ├── scatter_TL0.png  … scatter_2PP.png
    ├── timeseries_TL0.png  … timeseries_2PP.png
    ├── residual_correlations.png
    └── r_squared_comparison.png
```

---

## References

- Pascual, R., Pascual-Fuster, B., & Climent, F. (2006). Cross-listing, price discovery and the informativeness of the trading process. *Journal of Financial Markets*, 9(2), 144–161. https://doi.org/10.1016/j.finmar.2006.01.002
- Hasbrouck, J. (1995). One security, many markets: Determining the contributions to price discovery. *Journal of Finance*, 50(4), 1175–1199.
- Harris, F. H., McInish, T. H., Shoesmith, G. L., & Wood, R. A. (1995). Cointegration, error correction, and price discovery on informationally linked security markets. *Journal of Financial and Quantitative Analysis*, 30(4), 563–579.
- Data: 30-second OHLCV bars from XETRA and BATS Europe, November–December 2024 (course-provided, WU Wien Market Microstructures).
