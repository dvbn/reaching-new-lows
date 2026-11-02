# Reaching New Lows? The Pandemic’s Consequences for Electricity Markets

David Benatia and Samuel Gingras. *The Energy Journal* 44(4), 2023, pp. 195–221.

[Published paper](https://doi.org/10.5547/01956574.44.4.dben) · [Author website](https://www.davidbenatia.com/research/)

MATLAB code for the New York electricity-market analysis.

## Usage

1. Extract the accompanying data ZIP into this repository. It supplies `data/`,
   `results/`, saved neural networks in `matlab/nnet/`, and the forecast logs.
2. Open the repository in MATLAB and run `run_analysis.m`.

The main analysis uses the supplied counterfactual load series and writes figures
and tables under `matlab/RESULTS/`. `matlab/short_term_analysis_SG.m` is the
coauthor's alternative analysis script. The `counterfactual_load_*_nnet.m`
scripts estimate the neural networks; the `*_figures.m` scripts produce their
figures. These scripts write under `figures/` and `tables/`.

The scripts use MATLAB timetable functions, Statistics and Machine Learning
Toolbox, and Deep Learning Toolbox; neural-network estimation can take time.
