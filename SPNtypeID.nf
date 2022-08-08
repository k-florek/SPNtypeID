#!/usr/bin/env nextflow

//Description: Workflow for the analysis of Streptococcus pneumoniae
//Author: Kelsey Florek
//eMail: kelsey.florek@slh.wisc.edu

nextflow.enable.dsl=2

params.test = false

if(params.test){
  testIDS = []

  println "Running test analysis using the following samples:"
  println testIDS
  Channel
      .fromSRA(testIDS)
      .set { raw_reads }

} else{
  //setup channel to read in and pair the fastq files
  Channel
      .fromFilePairs( "${params.reads}/*{R1,R2,_1,_2}*.{fastq,fq}.gz", size: 2 )
      .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads} Path must not end with /" }
      .set { raw_reads }
}

Channel
  .fromPath("$baseDir/configs/multiqc_config.yaml")
  .set { multiqc_config }

//Preprocessing Step: Change read names
process preProcess {
  publishDir "${params.outdir}/reads", mode: 'copy', pattern:"*.gz"

  input:
  tuple val(name), path(reads)

  output:
  tuple val(name), path("*_R{1,2}.fastq.gz"), emit: processed_reads

  script:
  if(params.name_split_on!=""){
    name = name.split(params.name_split_on)[0]
    outfiles = ["${name}_R1.fastq.gz","${name}_R2.fastq.gz"]
    """
    mv ${reads[0]} ${name}_R1.fastq.gz
    mv ${reads[1]} ${name}_R2.fastq.gz
    """
  }else{
    outfiles = reads
    """
    """
  }
}


//QC Step: Trim reads and remove adapters and remove PhiX contamination
process clean_reads {
  tag "$name"
  //errorStrategy 'ignore'
  publishDir "${params.outdir}/trimming/stats", mode: 'copy', pattern:"*.trim.txt"
  publishDir "${params.outdir}/trimming/reads", mode: 'copy', pattern:"*.gz"

  input:
  tuple val(name), path(processed_reads)

  output:
  tuple val(name), path("${name}_clean{_1,_2}.fastq.gz"), emit: cleaned_reads
  path("${name}.trim.txt"), emit: bbduk_files
  path("${name}.adapter.stats.txt"), emit: bbduk_stats

  script:
  """
  bbduk.sh in1=${processed_reads[0]} in2=${processed_reads[1]} out1=${name}_clean_1.fastq.gz out2=${name}_clean_2.fastq.gz outm=${name}.adapters.fq qtrim=${params.trimdirection} trimq=${params.qualitytrimscore} minlength=${params.minlength} ref=/bbmap/resources/adapters.fa stats=${name}.adapter.stats.txt k=31 hdist=1 tpe tbo &> ${name}.out
  grep -E 'Input:|QTrimmed:|Trimmed by overlap:|Total Removed:|Result:' ${name}.out > ${name}.trim.txt
  """
}

//Summary Step: Summarize BBDuk results
process bbduk_summary {
  //errorStrategy 'ignore'
  publishDir "${params.outdir}/trimming",mode:'copy'

  input:
  path("data*/*")

  output:
  path("bbduk_results.tsv"), emit: bbduk_tsv

  script:
  """
  #!/usr/bin/env python3
  import os
  import glob
  import pandas as pd
  from pandas import DataFrame

  # function for summarizing bbduk output
  def summarize_bbduk(file):
      # get sample id from file name and set up data list
      sample_id = os.path.basename(file).split(".")[0]
      data = []
      data.append(sample_id)
      with open(file,"r") as inFile:
          for i, line in enumerate(inFile):
              # get total number of reads
              if i == 0:
                  num_reads = line.strip().split("\\t")[1].replace(" reads ","")
                  data.append(num_reads)
              # get total number of reads removed
              if i == 3:
                  rm_reads = line.strip().split("\\t")[1].replace("reads ","")
                  rm_reads = rm_reads.rstrip()
                  data.append(rm_reads)
      return data

  # get all bbduk output files
  files = glob.glob("data*/*.trim.txt")

  # summarize bbduk output files
  results = map(summarize_bbduk,files)

  # convert results to data frame and write to tsv
  df = DataFrame(results,columns=['Sample','Total Reads','Reads Removed'])
  df.to_csv(f'bbduk_results.tsv',sep='\\t', index=False, header=True, na_rep='NaN')
  """
}

//QC Step: Run FastQC on processed and cleaned reads
process fastqc {
  //errorStrategy 'ignore'
  tag "$name"
  publishDir "${params.outdir}/fastqc", mode: 'copy',saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

  input:
  tuple val(name), path(reads)

  output:
  path("*_fastqc.{zip,html}"), emit: fastqc_results

  script:
  """
  fastqc -q  ${reads}
  """
}

//Summary Step: Summarize FastQC results
process fastqc_summary {
  //errorStrategy 'ignore'
  publishDir "${params.outdir}/fastqc", mode: 'copy'

  input:
  path(fastqc_results)

  output:
  path("fastqc_summary.tsv"), emit: fastqc_summary

  shell:
  """
  zips=`ls *.zip`

  for i in \$zips; do
      unzip -o \$i &>/dev/null;
  done

  fq_folders=\${zips}

  for folder in \$fq_folders; do
    folder=\${folder%.*}
    cat \$folder/summary.txt >> fastqc_summary.tsv
    ls .
  done;

  sed -i 's/.fastq.gz//g' fastqc_summary.tsv
  """
}


//Assembly step: Assemble trimmed reads with Shovill and map reads back to assembly
process shovill {
  //errorStrategy 'ignore'
  tag "$name"

  publishDir "${params.outdir}/assembled", mode: 'copy',pattern:"*.fa"
  publishDir "${params.outdir}/mapping/sams", mode: 'copy', pattern:"*.sam"

  input:
  tuple val(name), path(cleaned_reads)

  output:
  tuple val(name), path("${name}.contigs.fa"), emit: assembled_genomes
  tuple val(name), path("${name}.sam"), emit: sam_files

  script:
  """
  shovill --cpus ${task.cpus} --ram ${task.memory} --outdir ./output --R1 ${cleaned_reads[0]} --R2 ${cleaned_reads[1]} --force
  mv ./output/contigs.fa ${name}.contigs.fa
  bwa index ${name}.contigs.fa
  bwa mem ${name}.contigs.fa ${cleaned_reads[0]} ${cleaned_reads[1]} > ${name}.sam
  """
}

//Index and sort bam file then calculate coverage
process samtools {
  //errorStrategy 'ignore'
  tag "$name"

  publishDir "${params.outdir}/mapping/bams", mode: 'copy', pattern:"*.sorted.bam*"
  publishDir "${params.outdir}/mapping/depth", mode: 'copy', pattern:"*.depth.tsv"
  publishDir "${params.outdir}/mapping/stats", mode: 'copy', pattern:"*.stats.txt"

  input:
  tuple val(name), path(sam_files)

  output:
  path("*.depth.tsv"), emit: cov_files
  path("*.stats.txt"), emit: stats_multiqc
  path("*.sorted.*")

  shell:
  """
  samtools view -S -b ${name}.sam > ${name}.bam
  samtools sort ${name}.bam > ${name}.sorted.bam
  samtools index ${name}.sorted.bam
  samtools depth -a ${name}.sorted.bam > ${name}.depth.tsv
  samtools stats ${name}.sorted.bam > ${name}.stats.txt
  """
}

//QC Step: Calculate coverage stats
process coverage_stats {
  //errorStrategy 'ignore'
  publishDir "${params.outdir}/coverage", mode: 'copy'

  input:
  path("data*/*")

  output:
  path('coverage_stats.tsv'), emit: coverage_tsv

  script:
  """
  #!/usr/bin/env python3
  import glob
  import os
  from numpy import median
  from numpy import average

  # function for summarizing samtools depth files
  def summarize_depth(file):
      # get sample id from file name and set up data list
      sid = os.path.basename(file).split('.')[0]
      data = []
      # open samtools depth file and get depth
      with open(file,'r') as inFile:
          for line in inFile:
              data.append(int(line.strip().split()[2]))
      # get median and average depth
      med = int(median(data))
      avg = int(average(data))
      # return sample id, median and average depth
      result = f"{sid}\\t{med}\\t{avg}\\n"
      return result

  # get all samtools depth files
  files = glob.glob("data*/*.depth.tsv")
  print(files)

  # summarize samtools depth files
  results = map(summarize_depth,files)

  # write results to file
  with open('coverage_stats.tsv', 'w') as outFile:
      outFile.write("Sample\\tMedian Coverage\\tAverage Coverage\\n")
      for result in results:
          outFile.write(result)
  """
}


//QC Step: Run QUAST on assemblies
process quast {
  //errorStrategy 'ignore'
  tag "$name"

  publishDir "${params.outdir}/quast",mode:'copy',pattern: "*.quast.report.tsv"

  input:
  tuple val(name), path(assembled_genomes)

  output:
  path("*.transposed.quast.report.tsv"), emit: quast_files
  path("*.quast.report.tsv"), emit: multiqc_quast

  script:
  """
  quast.py ${name}.contigs.fa -o .
  mv report.tsv ${name}.quast.report.tsv
  mv transposed_report.tsv ${name}.transposed.quast.report.tsv
  """
}

//QC Step: Run QUAST on assemblies
process quast_summary {
  //errorStrategy 'ignore'
  publishDir "${params.outdir}/quast",mode:'copy'

  input:
  path("data*/*")

  output:
  path("quast_results.tsv"), emit: quast_tsv

  script:
  """
  #!/usr/bin/env python3
  import os
  import glob
  import pandas as pd
  from pandas import DataFrame

  # function for summarizing quast output
  def summarize_quast(file):
      # get sample id from file name and set up data list
      sample_id = os.path.basename(file).split(".")[0]
      # read in data frame from file
      df = pd.read_csv(file, sep='\\t')
      # get contigs, total length and assembly length columns
      df = df.iloc[:,[1,7,17]]
      # assign sample id as column
      df = df.assign(Sample=sample_id)
      # rename columns
      df = df.rename(columns={'# contigs (>= 0 bp)':'Contigs','Total length (>= 0 bp)':'Assembly Length (bp)'})
      # re-order data frame
      df = df[['Sample', 'Contigs','Assembly Length (bp)', 'N50']]
      return df

  # get quast output files
  files = glob.glob("data*/*.transposed.quast.tsv")

  # summarize quast output files
  dfs = map(summarize_quast,files)

  # concatenate dfs and write data frame to file
  dfs_concat = pd.concat(dfs)
  dfs_concat.to_csv(f'quast_results.tsv',sep='\\t', index=False, header=True, na_rep='NaN')
  """
}

//Run CG-Pipeline
process cg_pipeline {
  tag "$name"
  publishDir "${params.outdir}/cg_pipeline", mode: 'copy', pattern: '*_qual.tsv'
  publishDir "${params.outdir}/cg_pipeline/logs", mode: 'copy', pattern: '*.log'

  input:
  tuple val(name), path(processed_reads)

  output:
  path("${name}_qual.tsv"), emit: cg_pipeline_results
  path("${name}.error.log"), optional: true

  script:
    //Run the cg_pipeline
    """
    cat ${processed_reads[0]} ${processed_reads[1]} > ${name}_cgqc.fastq.gz
    run_assembly_readMetrics.pl --fast --numcpus ${task.cpus} -e 2200000 ${name}_cgqc.fastq.gz > ${name}_qual.tsv 2> ${name}.error.log
    find -name ${name}.error.log -size 0 -exec rm {} +
    """
}

//Check sample is SPN using Kraken
process kraken {
  tag "$name"
  publishDir "${params.outdir}/kraken", mode: 'copy', pattern: '*.kraken.txt'
  publishDir "${params.outdir}/kraken/logs", mode: 'copy', pattern: '*.log'

  input:
  tuple val(name), path(processed_reads)

  output:
  path("${name}.kraken.txt"), emit: kraken_results
  path("${name}.error.log"), optional: true

  script:
  """
  kraken --db /kraken-database/minikraken_20171013_4GB --threads ${task.cpus} --paired ${processed_reads[0]} ${processed_reads[1]} > ${name}_raw.txt 2> ${name}.error.log
  kraken-report --db /kraken-database/minikraken_20171013_4GB ${name}_raw.txt > ${name}.kraken.txt 2> ${name}.error.log
  find -name ${name}.error.log -size 0 -exec rm {} +
  """
}

//Run SeroBA
process seroba {
  tag "$name"
  publishDir "${params.outdir}/seroba", mode: 'copy', pattern: "*[_pred.tsv,_detailed_serogroup_info.txt]"
  publishDir "${params.outdir}/seroba/logs", mode: 'copy', pattern: '*.log'
  errorStrategy 'finish'

  input:
  tuple val(name), path(processed_reads)

  output:
  path("${name}_pred.tsv"), emit: seroba_results
  path("${name}_detailed_serogroup_info.txt"), optional: true
  path("${name}.error.log"), optional: true

  script:
  """
  seroba runSerotyping --noclean /seroba*/database ${processed_reads[0]} ${processed_reads[1]} ${name}
  mv ${name}/pred.tsv ${name}_pred.tsv > ${name}.out.log 2> ${name}.error.log
  if [ -f detailed_serogroup_info.txt ]; then
   mv detailed_serogroup_info.txt ${name}_detailed_serogroup_info.txt
  fi
  find -name ${name}.error.log -size 0 -exec rm {} +
  """
}

//Collect and format results of first three steps
process typing_summary {
  publishDir "${params.outdir}/kraken", mode: 'copy', pattern: 'kraken_results.tsv'
  publishDir "${params.outdir}/seroba", mode: 'copy', pattern: 'seroba_results.tsv'

  echo true

  input:
  path("data*/*")

  output:
  path("typing_results.tsv"), emit: typing_summary_results
  path("kraken_results.tsv")
  path("seroba_results.tsv")

  script:
  """
  #!/usr/bin/env python3
  import os, sys
  import glob, csv

  class result_values:
    def __init__(self,id):
        self.id = id
        self.comments = []
        self.quality = "NotRun"
        self.pass_cov_quality = False
        self.percent_strep = "NotRun"
        self.percent_spn = "NotRun"
        self.secondgenus = "NotRun"
        self.percent_secondgenus = "NotRun"
        self.pass_kraken = False
        self.pred = "NotRun"

  # get list of result files
  cg_result_list = glob.glob("data*/*_qual.tsv")
  kraken_list = glob.glob("data*/*.kraken.txt")
  seroba_list = glob.glob("data*/*_pred.tsv")

  results = {}

  #collect all cg_pipeline results
  for file in cg_result_list:
    id = file.split("/")[1].split("_qual")[0]
    result = result_values(id)
    with open(file,'r') as csvfile:
        dialect = csv.Sniffer().sniff(csvfile.read(1024))
        csvfile.seek(0)
        reader = csv.reader(csvfile,dialect)
        for row in reader:
            if "File" not in row:
                result.quality = float(row[5])
                if result.quality > 30.0:
                    result.pass_cov_quality = True
                if result.quality <= 30.0:
                    result.comments.append("Lower than 30.0 average base quality")

    results[id] = result

  #collect all kraken results
  for file in kraken_list:
    id = file.split("/")[1].split(".")[0]
    result = results[id]
    with open(file,'r') as csvfile:
        dialect = csv.Sniffer().sniff(csvfile.read(1024))
        csvfile.seek(0)
        reader = csv.reader(csvfile,dialect)
        secondgenus = ""
        percent_secondgenus = 0.0
        for row in reader:
            if row[4] == "1301":
                result.percent_strep = float(row[0])
                continue
            if row[4] == "1313":
                result.percent_spn = float(row[0])
                continue
            if row[3] == "G" and float(row[0]) > percent_secondgenus:
                secondgenus = row[5].strip()
                percent_secondgenus = float(row[0])
        result.secondgenus = secondgenus
        result.percent_secondgenus = percent_secondgenus
        if result.percent_spn == "NotRun":
            result.percent_spn = 0.0
        if result.percent_secondgenus == "NotRun":
            result.percent_secondgenus = 0.0
        if result.percent_strep == "NotRun":
            result.percent_strep = 0.0
        if result.percent_strep >= 82.0 and result.percent_spn >= 62.0 and result.percent_secondgenus < 1.0:
            result.pass_kraken = True
        if result.percent_strep < 82.0:
            result.comments.append("Less than 82.0% of reads are Strep")
        if result.percent_spn < 62.0:
            result.comments.append("Less than 62.0% of reads are SPN")
        if result.percent_secondgenus >= 1.0:
            result.comments.append("More than 1.0% of reads are from "+secondgenus)

    results[id] = result

  #collect all seroba results
  for file in seroba_list:
    id = file.split("/")[1].split("_pred")[0]
    result = results[id]
    with open(file,'r') as csvfile:
        dialect = csv.Sniffer().sniff(csvfile.read(1024))
        csvfile.seek(0)
        reader = csv.reader(csvfile,dialect)
        types = []
        for row in reader:
            types.append(row[1])
            try:
                result.comments.append(row[2])
            except IndexError:
                pass
        result.pred = " ".join(types)
    results[id] = result

  #create output file
  with open("typing_results.tsv",'w') as csvout:
    writer = csv.writer(csvout,delimiter='\\t')
    writer.writerow(["Sample","Avg Quality","Pass Qual","Percent Strep","Percent SPN","SecondGenus","Percent SecondGenus","Pass Kraken","Serotype","Comments"])
    for id in results:
        result = results[id]
        comments = "; ".join(result.comments)
        writer.writerow([result.id,result.quality,result.pass_cov_quality,result.percent_strep,result.percent_spn,result.secondgenus,result.percent_secondgenus,result.pass_kraken,result.pred,comments])
        #create output file
  with open("kraken_results.tsv",'w') as csvout:
    writer = csv.writer(csvout,delimiter='\\t')
    writer.writerow(["Sample","Percent Strep","Percent SPN","SecondGenus","Percent SecondGenus","Pass Kraken"])
    for id in results:
        result = results[id]
        writer.writerow([result.id,result.percent_strep,result.percent_spn,result.secondgenus,result.percent_secondgenus,result.pass_kraken])
  with open("seroba_results.tsv",'w') as csvout:
    writer = csv.writer(csvout,delimiter='\\t')
    writer.writerow(["Sample","Serotype"])
    for id in results:
        result = results[id]
        writer.writerow([result.id,result.pred])
  """
}


//QC Step: Merge QC results into one tsv
process merge_results {
  publishDir "${params.outdir}/", mode: 'copy'

  input:
  path("bbduk_results.tsv")
  path("quast_results.tsv")
  path("coverage_stats.tsv")
  path("typing_results.tsv")

  output:
  file('spntypeid_report.csv')

  script:
  """
  #!/usr/bin/env python3

  import os
  import glob
  import pandas as pd
  from functools import reduce

  files = glob.glob('*.tsv')

  dfs = []

  for file in files:
      df = pd.read_csv(file, header=0, delimiter='\\t')
      dfs.append(df)

  merged = reduce(lambda  left,right: pd.merge(left,right,on=['Sample'],
                                              how='left'), dfs)

  merged = merged.rename(columns={'Contigs':'Contigs (#)'})

  merged.to_csv('spntypeid_report.csv', index=False, sep=',', encoding='utf-8')
  """
}

//Summary Step: MultiQC
process multiqc {
  publishDir "${params.outdir}",mode:'copy'

  input:
  path("data*/*")
  path(config)

  output:
  path("*.html"), emit: multiqc_output

  script:
  """
  multiqc -c ${config} .
  """
}

workflow {

    preProcess(raw_reads)

    clean_reads(preProcess.out.processed_reads)

    bbduk_summary(clean_reads.out.bbduk_files.collect())

    processed = preProcess.out.processed_reads
    cleaned = clean_reads.out.cleaned_reads
    combined_reads = processed.concat(cleaned)

    fastqc(combined_reads)

    fastqc_summary(fastqc.out.collect())

    shovill(clean_reads.out.cleaned_reads)

    samtools(shovill.out.sam_files)

    coverage_stats(samtools.out.cov_files.collect())

    quast(shovill.out.assembled_genomes)

    quast_summary(quast.out.quast_files.collect())

    cg_pipeline(preProcess.out.processed_reads)

    kraken(preProcess.out.processed_reads)

    seroba(preProcess.out.processed_reads)

    typing_summary(cg_pipeline.out.cg_pipeline_results.mix(kraken.out.kraken_results,seroba.out.seroba_results).collect())

    merge_results(bbduk_summary.out.bbduk_tsv,coverage_stats.out.coverage_tsv,quast_summary.out.quast_tsv,typing_summary.out.typing_summary_results)

    multiqc(clean_reads.out.bbduk_files.mix(clean_reads.out.bbduk_stats,fastqc.out.fastqc_results,samtools.out.stats_multiqc,kraken.out.kraken_results,quast.out.multiqc_quast).collect(),multiqc_config)
}
