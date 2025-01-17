process RESULTS {
    label 'process_single'

    container "quay.io/wslh-bioinformatics/pandas@sha256:9ba0a1f5518652ae26501ea464f466dcbb69e43d85250241b308b96406cac458"

    input:
    path("bbduk_results.tsv")
    path("quality_stats.tsv")
    path("coverage_stats.tsv")
    path("quast_results.tsv")
    path("typing_results.tsv")
    path("kraken_ntc_data/*")
    path("kraken_version.yml")

    output:
    path('spntypeid_report.csv')   , emit: result_csv

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    #!/usr/bin/python3.7

    import os
    import glob
    import csv
    import pandas as pd
    import re
    from functools import reduce

    # Open Kraken version file to get Kraken version
    with open('kraken_version.yml', 'r') as krakenFile:
        for l in krakenFile.readlines():
            if "kraken DB:" in l.strip():
                krakenDBVersion = l.strip().split(':')[1].strip()

    # Get all tsv files and read them in as data frames
    files = glob.glob('*.tsv')
    dfs = []
    for file in files:
        df = pd.read_csv(file, header=0, delimiter='\\t')
        dfs.append(df)

    # Merge data frames
    merged = reduce(lambda  left,right: pd.merge(left,right,on=['Sample'],how='left'), dfs)

    # Merge comment columns and drop individual columns that were merged
    cols = ['Comments', 'Comments_x', 'Comments_y']
    merged['Combined'] = merged[cols].apply(lambda row: '; '.join(row.values.astype(str)), axis=1)
    merged['Combined'] = merged['Combined'].str.replace('nan; ', '')
    merged['Combined'] = merged['Combined'].str.replace('; nan', '')
    merged['Combined'] = merged['Combined'].str.replace('contamination', 'Contamination')
    merged['Combined'] = merged['Combined'].str.replace('nan', '')
    merged.drop(cols,axis=1,inplace=True)

    # Add kraken DB column
    merged = merged.assign(krakenDB=krakenDBVersion)

    # Add Workflow version column
    merged = merged.assign(workflowVersion='${workflow.manifest.version}')

    # Add NTC columns
    ntc = merged[merged['Sample'].str.match('NTC')]

    # Get Kraken NTC results
    kraken_ntc_results = glob.glob("kraken_ntc_data/*")

    # Add NTC column and calculate Kraken NTC read totals
    ntc_result = 'PASS'
    ntc_total_reads = []
    ntc_SPN_reads = []

    for file in kraken_ntc_results:
        id = file.split("/")[1].split(".kraken.txt")[0]
        spn_reads = 0
        total_reads = 0
        with open(file,'r') as csvfile:
            dialect = csv.Sniffer().sniff(csvfile.read(1024))
            csvfile.seek(0)
            reader = csv.reader(csvfile,dialect)
            for row in reader:
                if row[3] == "U":
                    total_reads += int(row[1])
                if "root" in row[5]:
                    total_reads += int(row[1])
                if row[4] == "1300":
                    spn_reads += int(row[1])

        if total_reads >= ${params.ntc_read_limit}:
            ntc_result = "FAIL"
        if spn_reads >= ${params.ntc_spn_read_limit}:
            ntc_result = "FAIL"

        ntc_total_reads.append(f"{id}: {total_reads}")
        ntc_SPN_reads.append(f"{id}: {spn_reads}")

    # Account for no NTC in data set
    if not kraken_ntc_results:
        merged = merged.assign(ntc_reads="No NTC in data set")
        merged = merged.assign(ntc_spn="No NTC in data set")
        merged = merged.assign(ntc_result="FAIL")

    # Otherwise add NTC totals to data frame
    else:
        merged = merged.assign(ntc_reads=", ".join(ntc_total_reads))
        merged = merged.assign(ntc_spn=", ".join(ntc_SPN_reads))
        merged = merged.assign(ntc_result=ntc_result)

    # Rename columns to nicer names
    merged = merged.rename(columns={'Contigs':'Contigs (#)','Combined':'Comments','ntc_reads':'Total NTC Reads','ntc_spn':'Total NTC SPN Reads','ntc_result':'NTC PASS/FAIL','krakenDB':'Kraken Database Version','workflowVersion':'SPNtypeID Version'})

    sample_names = merged['Sample'].tolist()
    sampleIDs = []
    runIDs = []

    for name in sample_names:
        if re.search('${params.run_name_regex}',name):
            runID = re.search('${params.run_name_regex}',name)
            runIDs.append(runID.group(0))
            sampleID = name.split('-')[0]
            sampleIDs.append(sampleID)
        else:
            runIDs.append('NA')
            sampleID = re.split(r'${params.split_regex}',name)[0]
            sampleIDs.append(sampleID)

    merged = merged.assign(Sample=sampleIDs)
    merged = merged.assign(Run=runIDs)

    # Put columns in specific order
    merged = merged[['Sample','Contigs (#)','Assembly Length (bp)','N50','Median Coverage','Average Coverage','Pass Coverage','Total Reads','Reads Removed','Median Read Quality','Average Read Quality','Pass Average Read Quality','Percent Strep','Percent SPN', 'SecondGenus','Percent SecondGenus','Pass Kraken','Serotype','Comments','Kraken Database Version','SPNtypeID Version','Total NTC Reads','Total NTC SPN Reads','NTC PASS/FAIL','Run']]

    # Write data frame to csv file
    merged.to_csv('spntypeid_report.csv', index=False, sep=',', encoding='utf-8')
    """
}
