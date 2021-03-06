#' Normalize observation variables.
#'
#' \code{normalize} normalizes observation variables based on the specified normalization method.
#'
#' @param population tbl with grouping (metadata) and observation variables.
#' @param variables character vector specifying observation variables.
#' @param strata character vector specifying grouping variables for grouping prior to normalization.
#' @param operation optional character string specifying method for normalization. This must be one of the strings \code{"standardize"} (default), \code{"robustize"}.
#' @param sample tbl containing sample that is used by normalization methods to estimate parameters. \code{sample} has same structure as \code{population}. Typically, \code{sample} corresponds to controls in the experiment.
#' @param ... arguments passed to normalization operation
#'
#' @return normalized data of the same class as \code{population}.
#'
#' @importFrom magrittr %>%
#' @importFrom magrittr %<>%
#' @importFrom rlang :=
#' @importFrom stats cor mad median sd setNames
#'
#' @examples
#' suppressMessages(suppressWarnings(library(magrittr)))
#' population <- tibble::data_frame(
#'    Metadata_group = c("control", "control", "control", "control",
#'                       "experiment", "experiment", "experiment", "experiment"),
#'    Metadata_batch = c("a", "a", "b", "b", "a", "a", "b", "b"),
#'    AreaShape_Area = c(10, 12, 15, 16, 8, 8, 7, 7)
#'  )
#' variables <- c('AreaShape_Area')
#' strata <- c('Metadata_batch')
#' sample <- population %>% dplyr::filter(Metadata_group == 'control')
#' cytominer::normalize(population, variables, strata, sample, operation = "standardize")
#'
#' @export
normalize <- function(population, variables, strata, sample,
                      operation = "standardize", ...) {
  scale <- function(data, location, dispersion, variables) {
    if (is.data.frame(data)) {
      futile.logger::flog.debug(paste0(
        "\t\tUsing base::scale (data is ",
        paste(class(data), collapse = ","),
        ")"
      ))

      dplyr::bind_cols(
        data %>% dplyr::select_(~-dplyr::one_of(variables)),
        data %>%
          dplyr::select_(.dots = variables) %>%
          as.matrix() %>%
          base::scale(
            center = as.matrix(location),
            scale = as.matrix(dispersion)
          ) %>%
          tibble::as_data_frame()
      )
    } else {
      futile.logger::flog.debug(paste0(
        "\t\tNot using base::scale (data is ",
        paste(class(data), collapse = ","),
        ")"
      ))

      for (variable in variables) {
        x <- rlang::sym(variable)

        m <- location[[variable]]

        s <- dispersion[[variable]]

        data %<>%
          dplyr::mutate(!! x := ((!! x) - m) / s)
      }

      data
    }
  }

  sample_is_df <- is.data.frame(sample)

  if (operation == "robustize") {
    location <- ifelse(sample_is_df,
      dplyr::funs(median(., na.rm = TRUE)),
      dplyr::funs(median)
    )

    dispersion <- ifelse(sample_is_df,
      dplyr::funs(mad(., na.rm = TRUE)),
      dplyr::funs(mad)
    )
  } else if (operation == "standardize") {
    location <- ifelse(sample_is_df,
      dplyr::funs(mean(., na.rm = TRUE)),
      dplyr::funs(mean)
    )

    dispersion <- ifelse(sample_is_df,
      dplyr::funs(sd(., na.rm = TRUE)),
      dplyr::funs(sd)
    )
  } else {
    error <- paste0("undefined operation `", operation, "'")

    futile.logger::flog.error(msg = error)

    stop(error)
  }

  futile.logger::flog.debug("Creating temp table for sample")
  sample %<>% dplyr::compute()
  futile.logger::flog.debug("Created temp table for sample")

  groups <-
    sample %>%
    dplyr::select_(.dots = strata) %>%
    dplyr::distinct() %>%
    dplyr::collect()

  Reduce(
    dplyr::union_all,
    Map(
      f = function(group) {
        futile.logger::flog.debug(group)
        futile.logger::flog.debug("\tstratum")
        stratum <-
          sample %>%
          dplyr::inner_join(y = group, by = names(group), copy = TRUE) %>%
          dplyr::compute()

        futile.logger::flog.debug("\tlocation")
        location <-
          stratum %>%
          dplyr::summarise_at(.funs = location, .vars = variables) %>%
          dplyr::collect()

        futile.logger::flog.debug("\tdispersion")
        dispersion <-
          stratum %>%
          dplyr::summarise_at(.funs = dispersion, .vars = variables) %>%
          dplyr::collect()

        futile.logger::flog.debug("\tscale")
        scaled <-
          population %>%
          dplyr::inner_join(y = group, by = names(group), copy = TRUE) %>%
          scale(location, dispersion, variables)
        futile.logger::flog.debug("\tscaled")

        scaled
      },
      split(x = groups, f = seq(nrow(groups)))
    )
  )
}
