#' Moving window through pseudotime
#' 
#' @export
#' @keywords internal
pseudotimeMovingWindow <- function(object, pseudotime, cells, moving.window, cells.per.window, name.by=c("mean","min","max")) {
  # Figure out pseudotime of cells
  pt <- object@pseudotime[cells,pseudotime]
  pt.order <- order(pt)
  
  # Figure out window size
  n.windows <- round(length(cells) / cells.per.window)
  c.windows.end <- round((1:n.windows) * (length(cells) / n.windows))
  c.windows.start <- c(0,head(c.windows.end, -1))+1
  
  # Assign cells to windows
  c.windows <- lapply(1:n.windows, function(window) return(cells[pt.order[c.windows.start[window]:c.windows.end[window]]]))
  i.windows <- embed(x=1:n.windows, dimension=moving.window)
  pt.windows <- lapply(1:dim(i.windows)[1], function(window) unlist(c.windows[i.windows[window,]]))
  
  # Figure out min/mean/max pseudotime of each window and name list.
  if (length(name.by) > 1) name.by <- name.by[1]
  namefunc <- get(name.by)
  names(pt.windows) <- round(unlist(lapply(pt.windows, function(window.cells) namefunc(object@pseudotime[window.cells,pseudotime]))), digits=3)
  
  return(pt.windows)
}

# Use this to process the gene cascade
#' Process a gene cascade
#' 
#' @param object An URD object
#' @param pseudotime (Character) Name of pseudotime
#' @param cells (Character vector) Cells to include
#' @param genes (Character vector) Genes to include
#' @param background.genes (Character vector) Genes to use for calculation of background noise model
#' @param moving.window (Numeric)
#' @param cells.per.window (Numeric) 
#' @param gene.cuts (Numeric) Number of groups 
#' @param expression.thresh (Numeric)
#' @param ignore.expression.before (Numeric)
#' @param plot.scaled (Logical)
#' @param verbose (Logical)
#' @param verbose.genes (Logical) If \code{verbose=T}, should the start time of each gene be printed?
#' @param limit.single.sigmoid ("none", "on", "off")
#' 
#' @return List
#' 
#' @export
geneCascadeProcess <- function(object, pseudotime, cells, genes, background.genes=sample(setdiff(rownames(object@logupx.data), object@var.genes),1000), moving.window=3, cells.per.window=10, plot.scaled=T, verbose=T, verbose.genes=F, limit.single.sigmoid.slopes=c("none","on","off"), k=50, a=0.05) {
  
  if (verbose) print(paste0(Sys.time(), ": Calculating moving window expression."))
  # Get moving window of cells by pseudotime
  pt.windows <- pseudotimeMovingWindow(object, pseudotime=pseudotime, cells=cells, moving.window=moving.window, cells.per.window=cells.per.window)
  # Calculate pseudotime parameters for each window
  pt.info <- as.data.frame(t(as.data.frame(lapply(pt.windows, function(cells) {
    pt <- object@pseudotime[cells,pseudotime]
    return(c(mean(pt), min(pt), max(pt), diff(range(pt))))
  }))))
  names(pt.info) <- c("mean","min","max","width")
  rownames(pt.info) <- 1:length(pt.windows)
  
  
  # Make aggregated expression data and scale it
  mean.expression <- as.data.frame(lapply(pt.windows, function(window.cells) apply(object@logupx.data[genes,window.cells], 1, mean.of.logs)))
  names(mean.expression) <- names(pt.windows)
  scaled.expression <- sweep(mean.expression, 1, apply(mean.expression, 1, max), "/")
  
  if (verbose) print(paste0(Sys.time(), ": Calculating background expression noise."))
  # Also calculate background data
  mean.expression.bg <- as.data.frame(lapply(pt.windows, function(window.cells) apply(object@logupx.data[background.genes,window.cells], 1, mean.of.logs)))
  names(mean.expression.bg) <- names(pt.windows)
  scaled.expression.bg <- sweep(mean.expression.bg, 1, apply(mean.expression.bg, 1, max), "/")
  sd.bg <- sd(unlist(scaled.expression.bg), na.rm=T)
  
  # Do impulse model fitting for all genes
  if (verbose) print(paste0(Sys.time(), ": Fitting impulse model for all genes."))
  impulse.fits <- lapply(genes, function(g) {
    if (verbose && verbose.genes) print(paste0(Sys.time(), ":   ", g))
    impulseFit(x=as.numeric(names(scaled.expression)), y=as.numeric(scaled.expression[g,]), limit.single.slope = limit.single.sigmoid.slopes, sd.bg = sd.bg, a = a, k = k, onset.thresh=0.1)
  })
  names(impulse.fits) <- genes
  
  # Get out onset/offset times
  timing <- data.frame(
    time.on=unlist(lapply(impulse.fits, function(x) x['time.on'])),
    time.off=unlist(lapply(impulse.fits, function(x) x['time.off'])),
    row.names=genes, stringsAsFactors=F
  )
  
  return(list(
    pt.windows=pt.windows,
    pt.info=pt.info,
    mean.expression=mean.expression,
    scaled.expression=scaled.expression,
    sd.bg=sd.bg,
    impulse.fits=impulse.fits,
    timing=timing
  ))
}

#' Plot Impulse Fits For a Gene Cascade
#' 
#' This allows checking that the impulse fits are working correctly. The
#' windowed data is plotted as black points for each gene, and the fit
#' is plotted in a thick line, color dependent on the type of fit that
#' was chosen: blue (linear), green (single sigmoid), red (double sigmoid).
#' Additionally, in thinner lines, other parameters are plotted. The onset
#' and offset times are plotted in blue (light for onset, dark for offset).
#' For sigmoid fits, the  
#' 
#' @param cascade (List) A gene cascade, such as generated by \code{\link{geneCascadeProcess}}
#' @param file (Path) A path to save the plot to as PDF (if NULL, display)
#' @export
geneCascadeImpulsePlots <- function(cascade, file=NULL, verbose=F) {
  ncol <- ceiling(sqrt(length(cascade$impulse.fits)))
  nrow <- ceiling(length(cascade$impulse.fits)/ncol)
  if (!is.null(file)) {
    pdf(file=file, width=ncol*4, height=nrow*4)
  }
  par(mfrow=c(nrow,ncol))
  x <- as.numeric(names(cascade$scaled.expression))
  for (g in names(cascade$impulse.fits)) {
    if (verbose) print(g)
    plot(x, cascade$scaled.expression[g,], pch=16, main=g, xlab="Pseudotime", ylab="Expression (scaled)")
    i <- cascade$impulse.fits[[g]]
    if (!is.na(i['type'])) {
      if (i['type'] == 0) {
        abline(b=i["a"], a=i["b"], col=rgb(0,0,1,0.7), lwd=5)
      }
      if (i['type'] == 1) {
        lines(x, impulse.single(x, b1=i['b1'], h0=i['h0'], h1=i['h1'], t1=i['t1']), col=rgb(0, 1, 0, 0.7), lwd=5)
        abline(h=i[c('h0','h1')], col=c('cyan','blue'))
        abline(v=i[c('t1','time.on','time.off')], col=c('cyan', 'orange', 'magenta'))
      } else {
        lines(x, impulse.double(x, b1=i['b1'], b2=i['b2'], h0=i['h0'], h1=i['h1'], h2=i['h2'], t1=i['t1'], t2=i['t2']), col=rgb(1, 0, 0, 0.7), lwd=5)
        abline(h=i[c('h0','h1','h2')], col=c('cyan','green','blue'))
        abline(v=i[c('t1','t2','time.on','time.off')], col=c('cyan', 'blue', 'orange', 'magenta'))
      }
    }
  }  
  if (!is.null(file)) {
    dev.off()
  }
}

# New version that calculates actual timepoints
#' Plot Gene Cascade Heatmap
#' 
#' @importFrom RColorBrewer brewer.pal
#' @importFrom gplots heatmap.2
#' @importFrom scales gradient_n_pal
#' 
#' @param cascade (list) A processed gene cascade from \code{\link{geneCascadeProcess}}
#' @param color.scale (Character vector)
#' @param add.time (Character or NULL) Either the name of a column of \code{@@meta} that contains actual time information
#' to label the x-axis of the heatmap or NULL to instead use pseudotime
#' @param times.annotate (Numeric vector)
#' @param annotation.list Color bar
#' @param row.font.size (Numeric) The font size of rows (gene names) should scale automatically, but this allows manual adjustment if needed.
#' @param max.font.size (Numeric) This is used to prevent the font from getting big enough that it runs off the page.
#' 
#' @export
geneCascadeHeatmap <- function(cascade, color.scale=brewer.pal(9, "YlOrRd"), add.time=NULL, times.annotate=seq(0,1,0.1), title="", annotation.list=NULL, row.font.size=1, max.font.size=0.9) {
  # Correct for NA timings
  timing <- cascade$timing
  timing[intersect(which(is.na(timing$time.on)), which(is.infinite(timing$time.off))), "time.on"] <- Inf
  gene.order <- order(timing$time.on, timing$time.off, na.last=F)
  cols <- gradient_n_pal(color.scale)(seq(0,1,length.out = 50))
  if (!is.null(add.time)) {
    time <- unlist(lapply(cascade$pt.windows, function(cells) mean(object@meta[cells, add.time])))
  } else {
    time <- as.numeric(names(cascade$pt.windows))
  }
  time.lab <- rep("", length(time))
  for (annotate in times.annotate) {
    gt <- which(time >= annotate)
    if (length(gt)>0) time.lab[min(gt)] <- as.character(annotate)
  }
  if (!is.null(annotation.list)) {
    annot <- data.frame(
      gene=rownames(cascade$timing)[gene.order],
      type=factor(rep(NA, length(gene.order)), levels=unique(names(annotation.list))),
      row.names=rownames(cascade$timing)[gene.order],
      stringsAsFactors=F
    )
    for (l in names(annotation.list)) {
      annot[annotation.list[[l]], "type"] <- l
    }
    heatmap.2(as.matrix(cascade$scaled.expression[gene.order,]), Rowv=F, Colv=F, dendrogram="none", col=cols, trace="none", density.info="none", key=F, labCol=time.lab, RowSideColors=as.character(annot$type), cexCol=0.8, cexRow=min((3.4-0.56*log(length(gene.order)))*row.font.size, max.font.size), margins = c(5,8), lwid=c(0.2,4), lhei=c(0.4, 4))
  } else {
    heatmap.2(as.matrix(cascade$scaled.expression[gene.order,]), Rowv=F, Colv=F, dendrogram="none", col=cols, trace="none", density.info="none", key=F, labCol=time.lab, cexCol=0.8, cexRow=min((3.4-0.56*log(length(gene.order)))*row.font.size, max.font.size), margins = c(5,8), lwid=c(0.3,4), lhei=c(0.4, 4))
  }
  title(title, line=1, adj=0.4)
}


