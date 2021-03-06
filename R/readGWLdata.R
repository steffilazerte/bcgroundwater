# Copyright 2015 Province of British Columbia
# 
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

#' Retrieve and format groundwater data from B.C. Data Catalogue
#' 
#' Go to the B.C. Groundwater Observation Well Monitoring
#' Network interactive map tool to find your 
#' well(s) of interest: https://www2.gov.bc.ca/gov/content?id=2D3DB9BA78DE4377AB4AE2DCEE1B409B
#' 
#' Note that well water levels are measured in meters below the ground. Thus 
#' higher values represent deeper levels. Therefore 
#' \code{Historical_Daily_Minimum} values will be greater than 
#' \code{Historical_Daily_Maximum} values, as they represent a lower water 
#' level.
#' 
#' Daily averages (\code{which = 'daily'}) are pre-calculated. Note that they 
#' only cover days marked as "Validated" in the full hourly dataset.
#' 
#' @param wells Character vector. The well number(s), accepts either 
#'   \code{OW000} or \code{000} format. Note that format OW000 requires three
#'   digit numbers, e.g. OW309, OW008, etc.
#' @param which Character. Which data to retrieve \code{all} hourly data, 
#'   \code{recent} hourly data, or all \code{daily} averages
#' @param url Character. Override the url location of the data
#' @param quiet Logical. Suppress progress messages?
#' 
#' @return A dataframe of the groundwater level observations.
#' @export
#' @examples \dontrun{
#' all_309 <- get_gwl(wells = 309)
#' recent_309 <- get_gwl(wells = "OW309", which = "recent")
#' daily_avg_309 <- get_gwl(wells = "OW309", which = "daily")
#' 
#' all_multi < get_gwl(wells = c(309, 89))
#' recent_multi <- get_gwl(wells = c("OW309", "OW089"), which = "recent")
#' daily_avg_multi <- get_gwl(wells = c("309", "89"), which = "daily")
#'}
#'
get_gwl <- function(wells, which = c("all", "recent", "daily"), 
                    url = NULL, quiet = FALSE) {
  
  which <- arg_match(which)
  
  if(is.null(url)) url <- "http://www.env.gov.bc.ca/wsd/data_searches/obswell/map/data/"
  
  if(!all(all(grepl("OW", wells)) || 
          is.numeric(wells) || 
          is.numeric(utils::type.convert(wells)))) {
    stop("wells can be specified either by 'OW000' or '000'. ",
         "Different formating cannot be mixed")
  } 
  
  if(all(!grepl("OW", wells))) {
    wells <- paste0("OW", sprintf("%03d", as.numeric(wells)))
  } else if(any(nchar(wells) != 5)) {
    stop("Wells in format OW000 must have 5 characters ",
         "(OW followed by a three-digit number, e.g. OW064)")
  }
  
  url <- paste0(url, wells, "-")
  
  if(!quiet) message("Retrieving data...")
  gwl <- lapply(url, download_gwl, which, quiet)
  
  if(!quiet) message("Formatting data...")
  gwl <- do.call('rbind', lapply(gwl, format_gwl, which, quiet))
  
  return(gwl)
}

#' Download groundwater data from url
#' 
#' @noRd
download_gwl <- function(url, which, quiet) {
  
  if(which == "all") which <- "data"
  if(which == "daily") which <- "average"
  
  if(httr::http_error(paste0(url, which, ".csv"))) {
    warning("Cannot access online data for well ", 
            substring(url, first = nchar(url)-5, last = nchar(url)-1),
            ". Either it doesn't exist or the online data is inaccessible ",
            "for some other reason.",
            call. = FALSE)
    return()
  }

  gwl_data <- httr::GET(paste0(url, which, ".csv"))
  httr::stop_for_status(gwl_data)
  gwl_data <- httr::content(gwl_data, as = "text", encoding = "UTF-8")
  
  gwl_avg <- httr::GET(paste0(url, "minMaxMean.csv"))
  httr::stop_for_status(gwl_avg)
  gwl_avg <- httr::content(gwl_avg, as = "text", encoding = "UTF-8")
  
  list(gwl_data, gwl_avg)
}

format_gwl <- function(data, which, quiet) {

  if(is.null(data)) return()
  
  welldf <- utils::read.csv(text = data[[1]], stringsAsFactors = FALSE)
  
  welldf$myLocation <- gsub("OW", "", welldf$myLocation)
  
  # For average data
  if("QualifiedTime" %in% names(welldf)) {
    welldf <- dplyr::rename(welldf, "Time" = "QualifiedTime")
    welldf$Approval <- "Validated"
  }

  # Merge with mean/min/max  
  if(which == "daily") welldf$Time <- as.Date(welldf$Time)
  if(which != "daily") welldf$Time <- as.POSIXct(welldf$Time, tz = "UTC")
  welldf$dummydate <- paste0("1800-", format(welldf$Time, "%m-%d"))
  
  well_avg <- utils::read.csv(text = data[[2]], stringsAsFactors = FALSE)
  well_avg <- well_avg[, names(well_avg)[names(well_avg) != "year"]]
  well_avg <- tidyr::spread(well_avg, "type", "Value")
  
  if(!all(is.na(well_avg$dummy_date))){
    welldf <- dplyr::left_join(welldf, 
                               well_avg[, c("dummydate", "max", "mean", "min")],
                               by = "dummydate")
  } else {
    welldf <- dplyr::mutate(welldf, max = NA, mean = NA, min = NA)
  }
  
  ################################
  # Need station name/location meta information!
  ################################
  
  ## Extract Well number and if deep or shallow from station name:
  
  # st_name <- welldf$Station_Name[1]
  # wl_num <- gsub("OBS\\w*\\s*WELL\\s*#*\\s*(\\d+)(\\s.+|$)", "\\1", st_name)
  # if (grepl("shallow", st_name, ignore.case = TRUE)) wl_num <- paste(wl_num, "shallow")
  # if (grepl("deep", st_name, ignore.case = TRUE)) wl_num <- paste(wl_num, "deep")

  # welldf$EMS_ID <- emsID
  
  welldf$EMS_ID <- NA
  welldf$Station_Name <- NA
  
  # Select and rename final variables
  welldf <- dplyr::select(welldf,
                          "Well_Num" = "myLocation",
                          "EMS_ID", "Station_Name",
                          "Date" = "Time", "GWL" = "Value", 
                          "Historical_Daily_Average" = "mean", 
                          "Historical_Daily_Minimum" = "min",
                          "Historical_Daily_Maximum" = "max",
                          "Status" = "Approval")
  
  return(welldf)
}

#' (DEFUNCT) Read in groundwater data from file downloaded from GWL tool
#'
#' Read in groundwater data from file downloaded from GWL tool
#' @param path The path to the csv
#' @param emsID The EMS ID of the well
#' @export
#' @return A dataframe of the groundwater level observations
readGWLdata <- function(path, emsID = NULL) {
  stop("'readGWLdata' is now defunct and has been replaced by 'get_gwl'.",
       "\nSee ?get_gwl for more details.")
}