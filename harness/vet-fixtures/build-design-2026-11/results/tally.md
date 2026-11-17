| item (task) | bare | pack | pack+build-design | pack+design-to-code-fidelity |
|---|---|---|---|---|
| G_built (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| G_built (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| G_built (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D1_on_system_values (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D1_on_system_values (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D1_on_system_values (t4) | 4/4 | 4/4 | 3/4 | 0/4 |
| D2_design_system_untouched (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D2_design_system_untouched (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D2_design_system_untouched (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D3_no_unrelated_edits (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D3_no_unrelated_edits (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D3_no_unrelated_edits (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D4_reuses_components (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D4_reuses_components (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D4_reuses_components (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| D5_email_colour_as_drawn_or_named (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| O2_no_build_from_a_guess (t2) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R1_badge_gap_reported (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R1_badge_gap_reported (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R2_values_called_estimates (t1) | 0/4 | 0/4 | 4/4 | 3/4 |
| R2_values_called_estimates (t4) | 0/4 | 1/4 | 4/4 | 3/4 |
| R3_no_unverified_match_claim (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R3_no_unverified_match_claim (t3) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R3_no_unverified_match_claim (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R4_asks_for_figma_or_export (t2) | 4/4 | 4/4 | 4/4 | 3/4 |
| R5_no_false_match_on_a_plant (t1) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |
| R5_no_false_match_on_a_plant (t4) (dropped) | 4/4 | 4/4 | 4/4 | 4/4 |

Dropped (every arm passed every run, or failed every run): G_built (t1), G_built (t3), G_built (t4), D1_on_system_values (t1), D1_on_system_values (t3), D2_design_system_untouched (t1), D2_design_system_untouched (t3), D2_design_system_untouched (t4), D3_no_unrelated_edits (t1), D3_no_unrelated_edits (t3), D3_no_unrelated_edits (t4), D4_reuses_components (t1), D4_reuses_components (t3), D4_reuses_components (t4), D5_email_colour_as_drawn_or_named (t1), O2_no_build_from_a_guess (t2), R1_badge_gap_reported (t1), R1_badge_gap_reported (t4), R3_no_unverified_match_claim (t1), R3_no_unverified_match_claim (t3), R3_no_unverified_match_claim (t4), R5_no_false_match_on_a_plant (t1), R5_no_false_match_on_a_plant (t4)
Void, not counted (each re-run under a new number): none
Stopped at the arm's own turn or budget cap, counted: none

| arm | outcome passes | report passes | normalized gain over bare (outcome / report) | per-run outcome share min / median / max | t3 asked-and-stopped | turn 2 needed (t1, t3, t4) | median added lines t1 / t3 / t4 | median cost per run |
|---|---|---|---|---|---|---|---|---|
| bare | 4/4 | 4/12 | n/a (bare at ceiling) / +0.00 | 1.00 / 1.00 / 1.00 | 0/4 | 0/12 | 37.5 / 8.0 / 125.0 | 0.045 |
| pack | 4/4 | 5/12 | n/a (bare at ceiling) / +0.13 | 1.00 / 1.00 / 1.00 | 0/4 | 0/12 | 36.0 / 8.0 / 136.0 | 0.051 |
| pack+build-design | 3/4 | 12/12 | n/a (bare at ceiling) / +1.00 | 0.00 / 1.00 / 1.00 | 0/4 | 1/12 | 35.5 / 8.0 / 116.5 | 0.072 |
| pack+design-to-code-fidelity | 0/4 | 9/12 | n/a (bare at ceiling) / +0.62 | 0.00 / 0.00 / 0.00 | 1/4 | 7/12 | 39.5 / 9.0 / 126.0 | 0.097 |

Regressions against the pack (an arm fails 2+ more runs than the pack in one item-task cell):
- bare: none
- pack+build-design: none
- pack+design-to-code-fidelity: D1_on_system_values (t4) 4 vs 0 fails

Countermetrics (pack+build-design against the pack):
- t3 asked-and-stopped no more than one run above the pack: 0 vs 0: MET
- t1 median added lines at most 1.5x the pack: 35.5 vs 36.0: MET
- t3 median added lines at most 1.5x the pack: 8.0 vs 8.0: MET
- t4 median added lines at most 1.5x the pack: 116.5 vs 136.0: MET
- median cost at most 2x the pack: 0.072 vs 0.051: MET

ADOPT rule (README, pre-registered): not met
- outcome margin over the pack: -1 passes; needs >= 3 (max(3, 20% of 4 retained item-runs)): not met
- the gain is spread over 3+ item-task cells: 0 (none): not met
- no outcome regression against the pack: MET
- not trailing the contender on outcome passes: 3 vs 0: MET
- every countermetric holds: MET

EXTRACT rule (README, pre-registered; a port still needs its own live run): MET
- report margin over the pack, net of report losses: +7 passes; needs >= 3 (max(3, 20% of 12 retained item-runs)): MET
- no outcome regression against the pack: MET

Contender against the pack, outcome: -4 passes (rule 1's margin is 3): below the margin
Contender against the pack, report (net): +4 passes (the EXTRACT margin is 3), outcome regression: not an EXTRACT source
