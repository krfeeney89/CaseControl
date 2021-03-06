# @file RunAnalyses.R
#
# Copyright 2017 Observational Health Data Sciences and Informatics
#
# This file is part of CaseControl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' Run a list of analyses
#'
#' @details
#' Run a list of analyses for the exposure-outcome-nesting cohorts of interest. This function will run
#' all specified analyses against all hypotheses of interest, meaning that the total number of outcome
#' models is `length(ccAnalysisList) * length(exposureOutcomeNestingCohortList)` (if all analyses
#' specify an outcome model should be fitted). When you provide several analyses it will determine
#' whether any of the analyses have anything in common, and will take advantage of this fact. For
#' example, if we specify several analyses that only differ in the way the outcome model is fitted,
#' then this function will extract the data and fit the propensity model only once, and re-use this in
#' all the analysis.
#'
#' @param connectionDetails                  An R object of type \code{ConnectionDetails} created using
#'                                           the function \code{createConnectionDetails} in the
#'                                           \code{DatabaseConnector} package.
#' @param cdmDatabaseSchema                  The name of the database schema that contains the OMOP CDM
#'                                           instance.  Requires read permissions to this database. On
#'                                           SQL Server, this should specifiy both the database and the
#'                                           schema, so for example 'cdm_instance.dbo'.
#' @param oracleTempSchema                   A schema where temp tables can be created in Oracle.
#' @param outcomeDatabaseSchema              The name of the database schema that is the location where
#'                                           the data used to define the outcome cohorts is available.
#'                                           If outcomeTable = CONDITION_ERA, outcomeDatabaseSchema is
#'                                           not used.  Requires read permissions to this database.
#' @param outcomeTable                       The tablename that contains the outcome cohorts.  If
#'                                           outcomeTable is not CONDITION_OCCURRENCE or CONDITION_ERA,
#'                                           then expectation is outcomeTable has format of COHORT
#'                                           table: COHORT_DEFINITION_ID, SUBJECT_ID,
#'                                           COHORT_START_DATE, COHORT_END_DATE.
#' @param exposureDatabaseSchema             The name of the database schema that is the location where
#'                                           the exposure data used to define the exposure cohorts is
#'                                           available. If exposureTable = DRUG_ERA,
#'                                           exposureDatabaseSchema is not used but assumed to be
#'                                           cdmSchema.  Requires read permissions to this database.
#' @param exposureTable                      The tablename that contains the exposure cohorts.  If
#'                                           exposureTable <> drug_era, then expectation is
#'                                           exposureTable has format of COHORT table:
#'                                           cohort_definition_id, subject_id, cohort_start_date,
#'                                           cohort_end_date.
#' @param nestingCohortDatabaseSchema        The name of the database schema that is the location where
#'                                           the nesting cohort is defined.
#' @param nestingCohortTable                 Name of the table holding the nesting cohort. This table
#'                                           should have the same structure as the cohort table.
#' @param ccAnalysisList                     A list of objects of type \code{ccAnalysis} as created
#'                                           using the \code{\link{createCcAnalysis}} function.
#' @param exposureOutcomeNestingCohortList   A list of objects of type
#'                                           \code{exposureOutcomeNestingCohort} as created using the
#'                                           \code{\link{createExposureOutcomeNestingCohort}} function.
#' @param outputFolder                       Name of the folder where all the outputs will written to.
#' @param prefetchExposureData               Should exposure data for the entire nesting cohort be fetched at
#'                                           the beginning, or should exposure data be fetch later specifically
#'                                           for a set of cases and controls. Prefetching can be faster
#'                                           when there are many outcomes but only few exposures. Prefetching
#'                                           does not speed up performance when covariates also need to be
#'                                           constructed.
#' @param getDbCaseDataThreads               The number of parallel threads to use for building the
#'                                           caseData objects.
#' @param selectControlsThreads              The number of parallel threads to use for selecting
#'                                           controls.
#' @param getDbExposureDataThreads           The number of parallel threads to use for fetchign data on
#'                                           exposures for cases and controls.
#' @param createCaseControlDataThreads       The number of parallel threads to use for creating case
#'                                           and control data including exposure status indicators
#' @param fitCaseControlModelThreads         The number of parallel threads to use for fitting the
#'                                           models.
#' @param cvThreads                          The number of parallel threads used for the
#'                                           cross-validation to determine the hyper-parameter when
#'                                           fitting the model.
#'
#' @export
runCcAnalyses <- function(connectionDetails,
                          cdmDatabaseSchema,
                          oracleTempSchema = cdmDatabaseSchema,
                          exposureDatabaseSchema = cdmDatabaseSchema,
                          exposureTable = "drug_era",
                          outcomeDatabaseSchema = cdmDatabaseSchema,
                          outcomeTable = "condition_era",
                          nestingCohortDatabaseSchema = cdmDatabaseSchema,
                          nestingCohortTable = "condition_era",
                          outputFolder = "./CcOutput",
                          ccAnalysisList,
                          exposureOutcomeNestingCohortList,
                          prefetchExposureData = FALSE,
                          getDbCaseDataThreads = 1,
                          selectControlsThreads = 1,
                          getDbExposureDataThreads = 1,
                          createCaseControlDataThreads = 1,
                          fitCaseControlModelThreads = 1,
                          cvThreads = 1) {
  for (exposureOutcomeNestingCohort in exposureOutcomeNestingCohortList) stopifnot(class(exposureOutcomeNestingCohort) ==
                                                                                     "exposureOutcomeNestingCohort")
  for (ccAnalysis in ccAnalysisList) stopifnot(class(ccAnalysis) == "ccAnalysis")
  uniqueExposureOutcomeNcList <- unique(OhdsiRTools::selectFromList(exposureOutcomeNestingCohortList,
                                                                    c("exposureId",
                                                                      "outcomeId",
                                                                      "nestingCohortId")))
  if (length(uniqueExposureOutcomeNcList) != length(exposureOutcomeNestingCohortList))
    stop("Duplicate exposure-outcome-nesting cohort combinations are not allowed")
  uniqueAnalysisIds <- unlist(unique(OhdsiRTools::selectFromList(ccAnalysisList, "analysisId")))
  if (length(uniqueAnalysisIds) != length(ccAnalysisList))
    stop("Duplicate analysis IDs are not allowed")

  if (!file.exists(outputFolder))
    dir.create(outputFolder)

  outcomeReference <- data.frame()
  for (ccAnalysis in ccAnalysisList) {
    analysisId <- ccAnalysis$analysisId
    for (exposureOutcomeNc in exposureOutcomeNestingCohortList) {
      exposureId <- .selectByType(ccAnalysis$exposureType, exposureOutcomeNc$exposureId, "exposure")
      outcomeId <- .selectByType(ccAnalysis$outcomeType, exposureOutcomeNc$outcomeId, "outcome")
      nestingCohortId <- .selectByType(ccAnalysis$nestingCohortType,
                                       exposureOutcomeNc$nestingCohortId,
                                       "nestingCohort")
      if (is.null(nestingCohortId)) {
        nestingCohortId <- NA
      }
      row <- data.frame(exposureId = exposureId,
                        outcomeId = outcomeId,
                        nestingCohortId = nestingCohortId,
                        analysisId = analysisId)
      outcomeReference <- rbind(outcomeReference, row)
    }
  }

  cdObjectsToCreate <- list()
  getDbCaseDataArgsList <- unique(OhdsiRTools::selectFromList(ccAnalysisList,
                                                              c("getDbCaseDataArgs")))
  for (d in 1:length(getDbCaseDataArgsList)) {
    getDbCaseDataArgs <- getDbCaseDataArgsList[[d]]
    analyses <- OhdsiRTools::matchInList(ccAnalysisList, getDbCaseDataArgs)
    analysesIds <- unlist(OhdsiRTools::selectFromList(analyses, "analysisId"))
    if (getDbCaseDataArgs$getDbCaseDataArgs$useNestingCohort) {
      nestingCohortIds <- unique(outcomeReference$nestingCohortId[outcomeReference$analysisId %in%
                                                                    analysesIds])
      for (nestingCohortId in nestingCohortIds) {
        if (is.na(nestingCohortId)) {
          idx <- outcomeReference$analysisId %in% analysesIds & is.na(outcomeReference$nestingCohortId)
        } else {
          idx <- outcomeReference$analysisId %in% analysesIds & outcomeReference$nestingCohortId ==
            nestingCohortId
        }
        outcomeIds <- unique(outcomeReference$outcomeId[idx])

        cdDataFileName <- .createCaseDataFileName(outputFolder, d, nestingCohortId)
        outcomeReference$caseDataFolder[idx] <- cdDataFileName
        if (!file.exists(cdDataFileName)) {
          args <- list(connectionDetails = connectionDetails,
                       cdmDatabaseSchema = cdmDatabaseSchema,
                       oracleTempSchema = oracleTempSchema,
                       outcomeDatabaseSchema = outcomeDatabaseSchema,
                       outcomeTable = outcomeTable,
                       nestingCohortDatabaseSchema = nestingCohortDatabaseSchema,
                       nestingCohortTable = nestingCohortTable,
                       outcomeIds = outcomeIds,
                       nestingCohortId = nestingCohortId,
                       getExposures = prefetchExposureData)
          if (prefetchExposureData) {
            args$exposureDatabaseSchema <- exposureDatabaseSchema
            args$exposureTable <- exposureTable
            args$exposureIds <- unique(outcomeReference$exposureId[idx])
          }
          args <- append(args, getDbCaseDataArgs$getDbCaseDataArgs)
          if (is.na(nestingCohortId)) {
            args$nestingCohortId <- NULL
            args$useObservationEndAsNestingEndDate <- FALSE
          }
          cdObjectsToCreate[[length(cdObjectsToCreate) + 1]] <- list(args = args,
                                                                     cdDataFileName = cdDataFileName)
        }
      }
    } else {
      idx <- outcomeReference$analysisId %in% analysesIds
      outcomeIds <- unique(outcomeReference$outcomeId[idx])
      cdDataFileName <- .createCaseDataFileName(outputFolder, d)
      idx <- outcomeReference$analysisId %in% analysesIds
      outcomeReference$caseDataFolder[idx] <- cdDataFileName
      if (!file.exists(cdDataFileName)) {
        args <- list(connectionDetails = connectionDetails,
                     cdmDatabaseSchema = cdmDatabaseSchema,
                     oracleTempSchema = oracleTempSchema,
                     outcomeDatabaseSchema = outcomeDatabaseSchema,
                     outcomeTable = outcomeTable,
                     nestingCohortDatabaseSchema = nestingCohortDatabaseSchema,
                     nestingCohortTable = nestingCohortTable,
                     outcomeIds = outcomeIds,
                     nestingCohortId = nestingCohortId,
                     getExposures = prefetchExposureData)
        if (prefetchExposureData) {
          args$exposureDatabaseSchema <- exposureDatabaseSchema
          args$exposureTable <- exposureTable
          args$exposureIds <- unique(outcomeReference$exposureId[idx])
        }
        args <- append(args, getDbCaseDataArgs$getDbCaseDataArgs)
        cdObjectsToCreate[[length(cdObjectsToCreate) + 1]] <- list(args = args,
                                                                   cdDataFileName = cdDataFileName)
      }
    }
  }

  ccObjectsToCreate <- list()
  selectControlsArgsList <- unique(OhdsiRTools::selectFromList(ccAnalysisList,
                                                               c("selectControlsArgs")))
  for (i in 1:length(selectControlsArgsList)) {
    selectControlsArgs <- selectControlsArgsList[[i]]
    analyses <- OhdsiRTools::matchInList(ccAnalysisList, selectControlsArgs)
    analysesIds <- unlist(OhdsiRTools::selectFromList(analyses, "analysisId"))
    cdDataFileNames <- unique(outcomeReference$caseDataFolder[outcomeReference$analysisId %in% analysesIds])
    for (cdDataFileName in cdDataFileNames) {
      cdId <- gsub("^.*caseData_", "", cdDataFileName)
      idx <- outcomeReference$analysisId %in% analysesIds & outcomeReference$caseDataFolder ==
        cdDataFileName
      outcomeIds <- unique(outcomeReference$outcomeId[idx])
      for (outcomeId in outcomeIds) {
        ccFilename <- .createCaseControlsFileName(outputFolder, cdId, i, outcomeId)
        outcomeReference$caseControlsFile[idx & outcomeReference$outcomeId == outcomeId] <- ccFilename
        if (!file.exists(ccFilename)) {
          args <- list(outcomeId = outcomeId)
          args <- append(args, selectControlsArgs$selectControlsArgs)
          ccObjectsToCreate[[length(ccObjectsToCreate) + 1]] <- list(args = args,
                                                                     cdDataFileName = cdDataFileName,
                                                                     ccFilename = ccFilename)
        }
      }
    }
  }

  edObjectsToCreate <- list()
  for (ccFilename in unique(outcomeReference$caseControlsFile)) {
    analysisIds <- unique(outcomeReference$analysisId[outcomeReference$caseControlsFile == ccFilename])
    edArgsList <- unique(sapply(ccAnalysisList, function(x) if (x$analysisId %in% analysisIds)
      return(x$getDbExposureDataArgs), simplify = FALSE))
    edArgsList <- edArgsList[!sapply(edArgsList, is.null)]
    for (ed in 1:length(edArgsList)) {
      edArgs <- edArgsList[[ed]]
      analysisIds <- unlist(unique(OhdsiRTools::selectFromList(OhdsiRTools::matchInList(ccAnalysisList,
                                                                                        list(getDbExposureDataArgs = edArgs)),
                                                               "analysisId")))
      idx <- outcomeReference$caseControlsFile == ccFilename & outcomeReference$analysisId %in%
        analysisIds
      exposureIds <- unique(outcomeReference$exposureId[idx])
      edFilename <- .createExposureDataFileName(ccFilename, ed)
      outcomeReference$exposureDataFile[idx] <- edFilename
      if (!file.exists(edFilename)) {
        args <- list(connectionDetails = connectionDetails,
                     oracleTempSchema = oracleTempSchema,
                     exposureDatabaseSchema = exposureDatabaseSchema,
                     exposureTable = exposureTable,
                     exposureIds = exposureIds,
                     cdmDatabaseSchema = cdmDatabaseSchema)
        if (prefetchExposureData) {
          cdFilename <- outcomeReference$caseDataFolder[outcomeReference$caseControlsFile == ccFilename][1]
        } else {
          cdFilename <- NULL
        }
        args <- append(args, edArgs)
        edObjectsToCreate[[length(edObjectsToCreate) + 1]] <- list(args = args,
                                                                   ccFilename = ccFilename,
                                                                   cdFilename = cdFilename,
                                                                   edFilename = edFilename)
      }
    }
  }

  ccdObjectsToCreate <- list()
  for (edFilename in unique(outcomeReference$exposureDataFile)) {
    analysisIds <- unique(outcomeReference$analysisId[outcomeReference$exposureDataFile == edFilename])
    ccdArgsList <- unique(sapply(ccAnalysisList, function(x) if (x$analysisId %in% analysisIds)
      return(x$createCaseControlDataArgs), simplify = FALSE))
    ccdArgsList <- ccdArgsList[!sapply(ccdArgsList, is.null)]
    for (ccd in 1:length(ccdArgsList)) {
      ccdArgs <- ccdArgsList[[ccd]]
      analysisIds <- unlist(unique(OhdsiRTools::selectFromList(OhdsiRTools::matchInList(ccAnalysisList,
                                                                                        list(createCaseControlDataArgs = ccdArgs)),
                                                               "analysisId")))
      idx <- outcomeReference$exposureDataFile == edFilename & outcomeReference$analysisId %in%
        analysisIds
      exposureIds <- unique(outcomeReference$exposureId[idx])
      for (exposureId in exposureIds) {
        ccdFilename <- .createCaseControlDataFileName(edFilename, exposureId, ccd)
        outcomeReference$caseControlDataFile[idx & outcomeReference$exposureId == exposureId] <- ccdFilename
        if (!file.exists(ccdFilename)) {
          args <- ccdArgs
          args$exposureId <- exposureId
          ccdObjectsToCreate[[length(ccdObjectsToCreate) + 1]] <- list(args = args,
                                                                       ccdFilename = ccdFilename,
                                                                       edFilename = edFilename)
        }
      }
    }
  }

  modelObjectsToCreate <- list()
  for (ccAnalysis in ccAnalysisList) {
    # ccAnalysis = ccAnalysisList[[1]]
    analysisFolder <- file.path(outputFolder, paste("Analysis_", ccAnalysis$analysisId, sep = ""))
    if (!file.exists(analysisFolder))
      dir.create(analysisFolder)
    for (i in which(outcomeReference$analysisId == ccAnalysis$analysisId)) {
      # i = 1
      exposureId <- outcomeReference$exposureId[i]
      outcomeId <- outcomeReference$outcomeId[i]
      edFilename <- outcomeReference$exposureDataFile[i]
      ccdFilename <- outcomeReference$caseControlDataFile[i]
      modelFilename <- .createModelFileName(analysisFolder, exposureId, outcomeId)
      outcomeReference$modelFile[i] <- modelFilename
      if (!file.exists(modelFilename)) {
        args <- ccAnalysis$fitCaseControlModelArgs
        args$control$threads <- cvThreads
        modelObjectsToCreate[[length(modelObjectsToCreate) + 1]] <- list(args = args,
                                                                         ccdFilename = ccdFilename,
                                                                         edFilename = edFilename,
                                                                         modelFilename = modelFilename)
      }
    }
  }

  saveRDS(outcomeReference, file.path(outputFolder, "outcomeModelReference.rds"))

  ### Actual construction of objects ###

  writeLines("*** Creating caseData objects ***")
  createCaseDataObject <- function(params) {
    caseData <- do.call("getDbCaseData", params$args)
    saveCaseData(caseData, params$cdDataFileName)
  }
  if (length(cdObjectsToCreate) != 0) {
    cluster <- OhdsiRTools::makeCluster(getDbCaseDataThreads)
    OhdsiRTools::clusterRequire(cluster, "CaseControl")
    dummy <- OhdsiRTools::clusterApply(cluster, cdObjectsToCreate, createCaseDataObject)
    OhdsiRTools::stopCluster(cluster)
  }

  writeLines("*** Creating caseControls objects ***")
  createCaseControlsObject <- function(params) {
    caseData <- loadCaseData(params$cdDataFileName, readOnly = TRUE)
    params$args$caseData <- caseData
    caseControls <- do.call("selectControls", params$args)
    saveRDS(caseControls, params$ccFilename)
  }
  if (length(ccObjectsToCreate) != 0) {
    cluster <- OhdsiRTools::makeCluster(selectControlsThreads)
    OhdsiRTools::clusterRequire(cluster, "CaseControl")
    dummy <- OhdsiRTools::clusterApply(cluster, ccObjectsToCreate, createCaseControlsObject)
    OhdsiRTools::stopCluster(cluster)
  }

  writeLines("*** Creating caseControlsExposure objects ***")
  createExposureDataObject <- function(params) {
    caseControls <- readRDS(params$ccFilename)
    params$args$caseControls <- caseControls
    if (!is.null(params$cdFilename)) {
      caseData <- loadCaseData(params$cdFilename)
      params$args$caseData <- caseData
    }
    exposureData <- do.call("getDbExposureData", params$args)
    saveCaseControlsExposure(exposureData, params$edFilename)
  }
  if (length(edObjectsToCreate) != 0) {
    cluster <- OhdsiRTools::makeCluster(getDbExposureDataThreads)
    OhdsiRTools::clusterRequire(cluster, "CaseControl")
    dummy <- OhdsiRTools::clusterApply(cluster, edObjectsToCreate, createExposureDataObject)
    OhdsiRTools::stopCluster(cluster)
  }

  writeLines("*** Creating caseControlData objects ***")
  createCaseControlDataObject <- function(params) {
    exposureData <- loadCaseControlsExposure(params$edFilename)
    params$args$caseControlsExposure <- exposureData
    caseControlData <- do.call("createCaseControlData", params$args)
    saveRDS(caseControlData, params$ccdFilename)
  }
  if (length(ccdObjectsToCreate) != 0) {
    cluster <- OhdsiRTools::makeCluster(createCaseControlDataThreads)
    OhdsiRTools::clusterRequire(cluster, "CaseControl")
    dummy <- OhdsiRTools::clusterApply(cluster, ccdObjectsToCreate, createCaseControlDataObject)
    OhdsiRTools::stopCluster(cluster)
  }

  writeLines("*** Creating case-control model objects ***")
  createCaseControlModelObject <- function(params) {
    caseControlData <- readRDS(params$ccdFilename)
    exposureData <- loadCaseControlsExposure(params$edFilename)
    params$args$caseControlData <- caseControlData
    params$args$caseControlsExposure <- exposureData
    model <- do.call("fitCaseControlModel", params$args)
    saveRDS(model, params$modelFilename)
  }
  if (length(modelObjectsToCreate) != 0) {
    cluster <- OhdsiRTools::makeCluster(fitCaseControlModelThreads)
    OhdsiRTools::clusterRequire(cluster, "CaseControl")
    dummy <- OhdsiRTools::clusterApply(cluster, modelObjectsToCreate, createCaseControlModelObject)
    OhdsiRTools::stopCluster(cluster)
  }

  invisible(outcomeReference)
}

.createCaseDataFileName <- function(folder, loadId, nestingCohortId = NULL) {
  name <- paste0("caseData_cd", loadId)
  if (!is.null(nestingCohortId) && !is.na(nestingCohortId))
    name <- paste0(name, "_n", nestingCohortId)
  return(file.path(folder, name))
}

.createCaseControlsFileName <- function(folder, cdId, i, outcomeId) {
  name <- paste0("caseControls_", cdId, "_cc", i, "_o", outcomeId, ".rds")
  return(file.path(folder, name))
}

.createExposureDataFileName <- function(ccFilename, ed) {
  name <- gsub("caseControls_", "exposureData_", ccFilename)
  name <- gsub(".rds", "", name)
  name <- paste0(name, "_ed", ed)
  return(name)
}

.createCaseControlDataFileName <- function(edFilename, exposureId, ccd) {
  name <- gsub("exposureData_", "ccd_", edFilename)
  name <- paste0(name, "_e", exposureId, "_ccd", ccd, ".rds")
  return(name)
}

.createModelFileName <- function(folder, exposureId, outcomeId) {
  name <- paste("model_e", exposureId, "_o", outcomeId, ".rds", sep = "")
  return(file.path(folder, name))
}

.selectByType <- function(type, value, label) {
  if (is.null(type)) {
    if (is.list(value)) {
      stop(paste("Multiple ",
                 label,
                 "s specified, but none selected in analyses (comparatorType).",
                 sep = ""))
    }
    return(value)
  } else {
    if (!is.list(value) || is.null(value[type])) {
      stop(paste(label, "type not found:", type))
    }
    return(value[type])
  }
}

#' Create a summary report of the analyses
#'
#' @param outcomeReference   A data.frame as created by the \code{\link{runCcAnalyses}} function.
#'
#' @export
summarizeCcAnalyses <- function(outcomeReference) {
  columns <- c("analysisId", "exposureId", "nestingCohortId", "outcomeId")
  result <- outcomeReference[, columns]
  result$rr <- 0
  result$ci95lb <- 0
  result$ci95ub <- 0
  result$p <- 1
  result$cases <- 0
  result$controls <- 0
  result$exposedCases <- 0
  result$exposedControls <- 0
  result$logRr <- 0
  result$seLogRr <- 0
  for (i in 1:nrow(outcomeReference)) {
    if (outcomeReference$modelFile[i] != "") {
      model <- readRDS(outcomeReference$modelFile[i])
      result$rr[i] <- if (is.null(coef(model)))
        NA else exp(coef(model))
      result$ci95lb[i] <- if (is.null(coef(model)))
        NA else exp(confint(model)[1])
      result$ci95ub[i] <- if (is.null(coef(model)))
        NA else exp(confint(model)[2])
      if (is.null(coef(model))) {
        result$p[i] <- NA
      } else {
        z <- coef(model)/model$outcomeModelTreatmentEstimate$seLogRr
        result$p[i] <- 2 * pmin(pnorm(z), 1 - pnorm(z))
      }
      result$cases[i] <- model$outcomeCounts$cases
      result$controls[i] <- model$outcomeCounts$controls
      result$exposedCases[i] <- model$outcomeCounts$exposedCases
      result$exposedControls[i] <- model$outcomeCounts$exposedControls
      result$logRr[i] <- if (is.null(coef(model)))
        NA else coef(model)
      result$seLogRr[i] <- if (is.null(coef(model)))
        NA else model$outcomeModelTreatmentEstimate$seLogRr
    }
  }
  return(result)
}
