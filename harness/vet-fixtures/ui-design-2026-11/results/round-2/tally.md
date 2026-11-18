| item (task) | pack | pack+ui-design |
|---|---|---|
| G_built (t1) | 4/4 | 4/4 |
| D1_on_system_values (t1) | 4/4 | 4/4 |
| D2_design_system_untouched (t1) | 4/4 | 4/4 |
| D3_no_unrelated_edits (t1) | 4/4 | 4/4 |
| D4_reuses_components (t1) | 4/4 | 4/4 |
| D5_email_colour_as_drawn_or_named (t1) | 4/4 | 4/4 |
| R1_badge_gap_reported (t1) | 4/4 | 4/4 |
| R2_values_called_estimates (t1) | 0/4 | 4/4 |
| R3_no_unverified_match_claim (t1) | 4/4 | 4/4 |
| R5_no_false_match_on_a_plant (t1) | 4/4 | 4/4 |
| G_built (t4) | 4/4 | 4/4 |
| D1_on_system_values (t4) | 4/4 | 3/4 |
| D2_design_system_untouched (t4) | 4/4 | 4/4 |
| D3_no_unrelated_edits (t4) | 4/4 | 4/4 |
| D4_reuses_components (t4) | 4/4 | 4/4 |
| R1_badge_gap_reported (t4) | 4/4 | 4/4 |
| R2_values_called_estimates (t4) | 1/4 | 4/4 |
| R3_no_unverified_match_claim (t4) | 4/4 | 4/4 |
| R5_no_false_match_on_a_plant (t4) | 4/4 | 4/4 |
| TP (rv) | 10.5 10.5 10.5 9.5 | 11 10.5 11 11 |
| FA (rv) | 1 0 0 0 | 1 0 0 0 |
| RV_no_edit (rv) | 4/4 | 4/4 |

Void, not counted: none

| rule | measured | result |
|---|---|---|
| L1 loads on t1, t4, rv, p1 (>= 3 of 4 each) | t1 3/4, t4 4/4, rv 4/4, p1 4/4 | MET |
| L2 quiet on c2 and c3 (<= 1 of 8) | 0 of 8 (c1, reported only: 0 of 4) | MET |
| Q1 no build regression | none | MET |
| Q2 R2 gain >= 3 | 8 vs 1 of 8 (+7) | MET |
| Q3 no false match (R5 fails <= 1; R3 fails <= pack + 1) | R5 fails 0; R3 fails 0 vs 0 | MET |
| Q4 review no worse (TP >= pack - 2; FA <= pack + 1; edits <= pack + 1) | TP 43.5 vs 41.0 of 44; FA 1 vs 1 of 40; edited 0 vs 0 of 4 | MET |
| C t1 median added lines <= 1.5x pack | 41.0 vs 38.0 | MET |
| C t4 median added lines <= 1.5x pack | 148.0 vs 126.0 | MET |
| C median cost on t1, t4, rv <= 2x pack | 0.101 vs 0.060 | MET |
| C stopped to ask on t1, t4 <= pack + 1 | 0 vs 0 of 8 | MET |

Ships model-invoked: yes, every rule met
