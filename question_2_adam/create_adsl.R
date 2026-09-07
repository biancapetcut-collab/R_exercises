# =============================================================================
# Program:      create_adsl.R
# Purpose:      Create the ADaM ADSL (Subject-Level Analysis Dataset) using
#               {admiral} and tidyverse tools, following the Pharmaverse
#               "Creating ADSL" example, extended with the custom variables
#               required for this exercise: AGEGR9/AGEGR9N, TRTSDTM/TRTSTMF,
#               ITTFL, LSTAVLDT.
# Input:        pharmaversesdtm::dm, ::vs, ::ex, ::ds, ::ae
# Output:       adsl (ADaM ADSL data frame)
#               question_2_adam/adsl.rds / adsl.csv
# =============================================================================

library(admiral)
library(dplyr, warn.conflicts = FALSE)
library(pharmaversesdtm)
library(lubridate)
library(stringr)

# ----------------------------------------------------------------------------
# 1. Read in data
# ----------------------------------------------------------------------------
dm <- pharmaversesdtm::dm
vs <- pharmaversesdtm::vs
ex <- pharmaversesdtm::ex
ds <- pharmaversesdtm::ds
ae <- pharmaversesdtm::ae

dm <- convert_blanks_to_na(dm)
vs <- convert_blanks_to_na(vs)
ex <- convert_blanks_to_na(ex)
ds <- convert_blanks_to_na(ds)
ae <- convert_blanks_to_na(ae)

# DM is the basis for ADSL
adsl <- dm %>%
  select(-DOMAIN)

# ----------------------------------------------------------------------------
# 2. Treatment variables (planned/actual treatment)
# ----------------------------------------------------------------------------
adsl <- adsl %>%
  mutate(TRT01P = ARM, TRT01A = ACTARM)

# ----------------------------------------------------------------------------
# 3. TRTSDTM / TRTSTMF (and TRTEDTM / TRTETMF)
#
#    Per the exercise specification: derive the datetime of the first
#    exposure record with a valid dose. A valid dose is EXDOSE > 0, or
#    EXDOSE == 0 with EXTRT containing "PLACEBO". Any missing hour/minute is
#    imputed to "00" (highest_imputation = "h" permits hour, minute and
#    second components to be imputed when missing; time_imputation supplies
#    "00:00:00" as the imputed value). Per admiral's default
#    `ignore_seconds_flag = TRUE`, if ONLY the seconds component were missing
#    (hour and minute already present) the imputation flag would NOT be
#    populated -- exactly matching the requirement "if only seconds are
#    missing then do not populate the imputation flag (TRTSTMF)".
# ----------------------------------------------------------------------------
ex_ext <- ex %>%
  derive_vars_dtm(
    dtc = EXSTDTC,
    new_vars_prefix = "EXST",
    highest_imputation = "h",
    time_imputation = "00:00:00"
  ) %>%
  derive_vars_dtm(
    dtc = EXENDTC,
    new_vars_prefix = "EXEN",
    highest_imputation = "h",
    time_imputation = "00:00:00"
  )

adsl <- adsl %>%
  derive_vars_merged(
    dataset_add = ex_ext,
    filter_add = (EXDOSE > 0 | (EXDOSE == 0 & str_detect(EXTRT, "PLACEBO"))) &
      !is.na(EXSTDTM),
    new_vars = exprs(TRTSDTM = EXSTDTM, TRTSTMF = EXSTTMF),
    order = exprs(EXSTDTM, EXSEQ),
    mode = "first",
    by_vars = exprs(STUDYID, USUBJID)
  ) %>%
  derive_vars_merged(
    dataset_add = ex_ext,
    filter_add = (EXDOSE > 0 | (EXDOSE == 0 & str_detect(EXTRT, "PLACEBO"))) &
      !is.na(EXENDTM),
    new_vars = exprs(TRTEDTM = EXENDTM, TRTETMF = EXENTMF),
    order = exprs(EXENDTM, EXSEQ),
    mode = "last",
    by_vars = exprs(STUDYID, USUBJID)
  ) %>%
  derive_vars_dtm_to_dt(source_vars = exprs(TRTSDTM, TRTEDTM))

# ----------------------------------------------------------------------------
# 4. ITTFL: "Y" if ARM is populated (i.e. subject was randomized), else "N"
# ----------------------------------------------------------------------------
adsl <- adsl %>%
  mutate(ITTFL = if_else(!is.na(ARM), "Y", "N"))

# ----------------------------------------------------------------------------
# 5. Disposition variables (End of Study date/status/reason, Randomization date)
# ----------------------------------------------------------------------------
ds_ext <- derive_vars_dt(
  ds,
  dtc = DSSTDTC,
  new_vars_prefix = "DSST"
)

format_eosstt <- function(x) {
  case_when(
    x %in% c("COMPLETED") ~ "COMPLETED",
    x %in% c("SCREEN FAILURE") ~ NA_character_,
    TRUE ~ "DISCONTINUED"
  )
}

adsl <- adsl %>%
  derive_vars_merged(
    dataset_add = ds_ext,
    by_vars = exprs(STUDYID, USUBJID),
    new_vars = exprs(EOSDT = DSSTDT),
    filter_add = DSCAT == "DISPOSITION EVENT" & DSDECOD != "SCREEN FAILURE"
  ) %>%
  derive_vars_merged(
    dataset_add = ds,
    by_vars = exprs(STUDYID, USUBJID),
    filter_add = DSCAT == "DISPOSITION EVENT",
    new_vars = exprs(EOSSTT = format_eosstt(DSDECOD)),
    missing_values = exprs(EOSSTT = "ONGOING")
  ) %>%
  derive_vars_merged(
    dataset_add = ds,
    by_vars = exprs(USUBJID),
    new_vars = exprs(DCSREAS = DSDECOD, DCSREASP = DSTERM),
    filter_add = DSCAT == "DISPOSITION EVENT" &
      !(DSDECOD %in% c("SCREEN FAILURE", "COMPLETED", NA))
  ) %>%
  derive_vars_merged(
    dataset_add = ds_ext,
    filter_add = DSDECOD == "RANDOMIZED",
    by_vars = exprs(STUDYID, USUBJID),
    new_vars = exprs(RANDDT = DSSTDT)
  )

# ----------------------------------------------------------------------------
# 6. Birth date and Analysis Age (kept for reference / age grouping)
# ----------------------------------------------------------------------------
adsl <- adsl %>%
  derive_vars_dt(
    new_vars_prefix = "BRTH",
    dtc = BRTHDTC
  ) %>%
  derive_vars_aage(
    start_date = BRTHDT,
    end_date = RANDDT
  )

# ----------------------------------------------------------------------------
# 7. AGEGR9 / AGEGR9N: Age grouping "<18", "18 - 50", ">50" -> 1, 2, 3
#    Based on DM.AGE (Analysis Age), per the exercise specification.
# ----------------------------------------------------------------------------
agegr9_lookup <- exprs(
  ~condition, ~AGEGR9, ~AGEGR9N,
  AGE < 18, "<18", 1,
  between(AGE, 18, 50), "18 - 50", 2,
  AGE > 50, ">50", 3
)

adsl <- adsl %>%
  derive_vars_cat(definition = agegr9_lookup)

# ----------------------------------------------------------------------------
# 8. Death variables (kept for context, needed for full ADSL derivations)
# ----------------------------------------------------------------------------
adsl <- adsl %>%
  derive_vars_dt(
    new_vars_prefix = "DTH",
    dtc = DTHDTC
  )

# ----------------------------------------------------------------------------
# 9. Population flag: SAFFL (Safety Population = received >= 1 valid dose)
# ----------------------------------------------------------------------------
adsl <- adsl %>%
  derive_var_merged_exist_flag(
    dataset_add = ex,
    by_vars = exprs(STUDYID, USUBJID),
    new_var = SAFFL,
    false_value = "N",
    missing_value = "N",
    condition = (EXDOSE > 0 | (EXDOSE == 0 & str_detect(EXTRT, "PLACEBO")))
  )

# ----------------------------------------------------------------------------
# 10. LSTAVLDT: Last known alive date
#
#     Set to the max of:
#      (1) last complete VS assessment date with a valid result
#          (VSSTRESN or VSSTRESC not both missing) and complete VSDTC datepart
#      (2) last complete AE onset date (AESTDTC datepart)
#      (3) last complete DS disposition start date (DSSTDTC datepart)
#      (4) TRTEDTM datepart (last exposure to treatment with a valid dose)
#
#     "Complete" dates only are considered (no partial-date imputation), so
#     convert_dtc_to_dt() is used with highest_imputation = "n" (the default),
#     which returns NA for any partial/missing date component.
# ----------------------------------------------------------------------------
vs_valid <- vs %>%
  filter(!(is.na(VSSTRESN) & is.na(VSSTRESC)))

adsl <- adsl %>%
  derive_vars_extreme_event(
    by_vars = exprs(STUDYID, USUBJID),
    events = list(
      event(
        dataset_name = "vs",
        order = exprs(VSDT, VSSEQ),
        condition = !is.na(VSDT),
        set_values_to = exprs(LSTAVLDT = VSDT, LALVSEQ = VSSEQ, LALVDOM = "VS")
      ),
      event(
        dataset_name = "ae",
        order = exprs(AESTDT, AESEQ),
        condition = !is.na(AESTDT),
        set_values_to = exprs(LSTAVLDT = AESTDT, LALVSEQ = AESEQ, LALVDOM = "AE")
      ),
      event(
        dataset_name = "ds",
        order = exprs(DSSTDT, DSSEQ),
        condition = !is.na(DSSTDT),
        set_values_to = exprs(LSTAVLDT = DSSTDT, LALVSEQ = DSSEQ, LALVDOM = "DS")
      ),
      event(
        dataset_name = "adsl",
        condition = !is.na(TRTEDTM),
        set_values_to = exprs(
          LSTAVLDT = TRTEDT, LALVSEQ = NA_integer_, LALVDOM = "ADSL"
        )
      )
    ),
    source_datasets = list(
      vs = derive_vars_dt(vs_valid, dtc = VSDTC, new_vars_prefix = "VS"),
      ae = derive_vars_dt(ae, dtc = AESTDTC, new_vars_prefix = "AEST"),
      ds = ds_ext,
      adsl = adsl
    ),
    tmp_event_nr_var = event_nr,
    order = exprs(LSTAVLDT, LALVSEQ, event_nr),
    mode = "last",
    new_vars = exprs(LSTAVLDT, LALVSEQ, LALVDOM)
  )

# ----------------------------------------------------------------------------
# 11. Checks
# ----------------------------------------------------------------------------
req_vars <- c(
  "STUDYID", "USUBJID", "AGEGR9", "AGEGR9N", "TRTSDTM", "TRTSTMF",
  "ITTFL", "LSTAVLDT"
)
stopifnot(all(req_vars %in% names(adsl)))
stopifnot(nrow(adsl) == n_distinct(adsl$USUBJID))
stopifnot(all(adsl$ITTFL %in% c("Y", "N")))
stopifnot(all(adsl$AGEGR9N[!is.na(adsl$AGEGR9N)] %in% 1:3))

cat("ADSL created successfully:", nrow(adsl), "subjects,", ncol(adsl), "variables.\n")
cat("\nAGEGR9 distribution:\n")
print(count(adsl, AGEGR9, AGEGR9N))
cat("\nITTFL distribution:\n")
print(count(adsl, ITTFL))
cat("\nTRTSTMF distribution:\n")
print(count(adsl, TRTSTMF))
cat("\nLSTAVLDT source domain (LALVDOM) distribution:\n")
print(count(adsl, LALVDOM))
cat("\nMissing LSTAVLDT:", sum(is.na(adsl$LSTAVLDT)), "\n")

# ----------------------------------------------------------------------------
# 12. Save output
# ----------------------------------------------------------------------------
saveRDS(adsl, file = file.path("question_2_adam", "adsl.rds"))
write.csv(adsl, file = file.path("question_2_adam", "adsl.csv"), row.names = FALSE, na = "")
