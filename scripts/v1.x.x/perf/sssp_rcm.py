# ------------------------------------------------------------------------
#  Gunrock (v1.x.x): Performance Testing Script(s)
# ------------------------------------------------------------------------

import os
import subprocess
import random

EXEDIR = "../../../build/bin"
NORCM_DATADIR = "/nfs/mario-2TB/gunrock_dataset/large"
RCM_DATADIR = "/nfs/mario-26TB/jwapman/large-rcm-perm"

NORCM_TAG = "no-rcm"
RCM_TAG = "rcm"

APPLICATION = "sssp"
EXECUTION = EXEDIR + "/" + APPLICATION

num_runs = 10

OPTIONS=""
OPTIONS+= "--num-runs=" + str(num_runs)
OPTIONS+=" --validation=each"
OPTIONS+=" --device=3"
OPTIONS+=" --64bit-SizeT=false"
OPTIONS+=" --64bit-VertexT=false"
OPTIONS+=" --mark-pred=false,true"
OPTIONS+=" --advance-mode=LB_CULL,LB,TWC"
OPTIONS+=" --remove-self-loops=false"
OPTIONS+=" --remove-duplicate-edges=false"
OPTIONS+=" --read-from-binary=false"

NORCM_EVAL_DIR = "NORCM_SSSP"
RCM_EVAL_DIR = "RCM_SSSP"

NAME = [""] * 72
GRAPH = [""] * 72

NAME[0]="ak2010"

NAME[ 1]="delaunay_n10"
NAME[ 2]="delaunay_n11"
NAME[ 3]="delaunay_n12"
NAME[ 4]="delaunay_n13"
NAME[ 5]="delaunay_n14"
NAME[ 6]="delaunay_n15"
NAME[ 7]="delaunay_n16"
NAME[ 8]="delaunay_n17"
NAME[ 9]="delaunay_n18"
NAME[10]="delaunay_n19"
NAME[11]="delaunay_n20"
NAME[12]="delaunay_n21"
NAME[13]="delaunay_n22"
NAME[14]="delaunay_n23"
NAME[15]="delaunay_n24"

NAME[21]="kron_g500-logn16"
NAME[22]="kron_g500-logn17"
NAME[23]="kron_g500-logn18"
NAME[24]="kron_g500-logn19"
NAME[25]="kron_g500-logn20"
NAME[26]="kron_g500-logn21"

# NAME[27]="rmat_n24_e16"
# GRAPH[27]="rmat --graph-scale=24 --graph-edgefactor=16"
# NAME[28]="rmat_n23_e32"
# GRAPH[28]="rmat --graph-scale=23 --graph-edgefactor=32"
# NAME[29]="rmat_n22_e64"
# GRAPH[29]="rmat --graph-scale=22 --graph-edgefactor=64"

NAME[31]="coAuthorsDBLP"
NAME[32]="coAuthorsCiteseer"
NAME[33]="coPapersDBLP"
NAME[34]="coPapersCiteseer"
NAME[35]="citationCiteseer"
NAME[36]="preferentialAttachment"

NAME[41]="soc-LiveJournal1"
NAME[42]="soc-twitter-2010"
# NAME[43]="soc-orkut"
NAME[44]="hollywood-2009"
NAME[45]="soc-sinaweibo"

NAME[51]="webbase-1M"
NAME[52]="arabic-2005"
NAME[53]="uk-2002"
NAME[54]="uk-2005"
NAME[55]="webbase-2001"
NAME[56]="indochina-2004"
NAME[57]="caidaRouterLevel"

# NAME[61]="roadNet-CA"
NAME[62]="belgium_osm"
NAME[63]="netherlands_osm"
NAME[64]="italy_osm"
NAME[65]="luxembourg_osm"
NAME[66]="great-britain_osm"
NAME[67]="germany_osm"
NAME[68]="asia_osm"
NAME[69]="europe_osm"
NAME[70]="road_usa"
NAME[71]="road_central"

subprocess.Popen(["mkdir -p " + NORCM_EVAL_DIR], shell=True)
subprocess.Popen(["mkdir -p " + RCM_EVAL_DIR], shell=True)

for idx in range(0, len(NAME)):
    if NAME[idx] == "":
        continue 

    SUFFIX = NAME[idx]

    subprocess.Popen(["mkdir -p " + NORCM_EVAL_DIR + "/" + SUFFIX], shell=True)
    subprocess.Popen(["mkdir -p " + RCM_EVAL_DIR + "/" + SUFFIX], shell=True)

    # undirected = true only! TODO: Check if this is valid
    for undirected in [True, False]:
        if GRAPH[idx] == "":
            NORCM_GRAPH_="market " + NORCM_DATADIR + "/" + NAME[idx] + "/" + NAME[idx] + ".mtx"
            RCM_GRAPH_="market " + RCM_DATADIR + "/" + NAME[idx] + "/" + NAME[idx] + ".mtx"
        else:
            NORCM_GRAPH_=GRAPH[idx]
            RCM_GRAPH_=GRAPH[idx]
        
        MARKS="UDIR"
        OPTIONS_=OPTIONS
        if undirected:
            OPTIONS_ = OPTIONS + " --undirected=true"
            MARKS="UDIR"
        else:
            OPTIONS_ = OPTIONS + " --undirected=false"
            MARKS="DIR"

        # Read the perm file and select the same 10 random vertices
        PERMFILE = RCM_DATADIR + "/" + NAME[idx] + "/" + NAME[idx] + "-perm.txt"
        try:
            with open(PERMFILE) as pfile:
                lines = pfile.read().splitlines()
        except FileNotFoundError:
            continue

        rcm_srcs = []
        for rcm_src_cnt in range(0, num_runs):
            rcm_srcs.append(random.randint(0, len(lines)))

        # Perm format: orig_idx = perm[rcm_idx]

        srcs = []
        for src_cnt in range(0, num_runs):
            srcs.append(lines[rcm_srcs[src_cnt]])

        NORCM_OPTIONS = ""
        NORCM_OPTIONS += " --tag=" + NORCM_TAG
        # NORCM_OPTIONS += " --undirected=true"
        NORCM_OPTIONS += " --src=" + ','.join([str(i) for i in srcs])
        NORCM_OPTIONS += " --jsondir=" + "./" + NORCM_EVAL_DIR + "/" + SUFFIX

        norcm_cmd= EXECUTION + " " + NORCM_GRAPH_ + " " + OPTIONS_ + NORCM_OPTIONS + " > ./" + NORCM_EVAL_DIR + "/" + SUFFIX + "/" + NAME[idx] + "." + MARKS + ".txt"

        RCM_OPTIONS = ""
        RCM_OPTIONS += " --tag=" + RCM_TAG
        # RCM_OPTIONS += " --undirected=false"
        RCM_OPTIONS += " --src=" + ','.join([str(i) for i in rcm_srcs])
        RCM_OPTIONS += " --jsondir=" + "./" + RCM_EVAL_DIR + "/" + SUFFIX

        rcm_cmd= EXECUTION + " " + RCM_GRAPH_ + " " + OPTIONS_ + RCM_OPTIONS + " > ./" + RCM_EVAL_DIR + "/" + SUFFIX + "/" + NAME[idx] + "." + MARKS + ".txt"

        print(norcm_cmd)
        norcm_proc = subprocess.Popen(norcm_cmd, shell=True)
        norcm_proc.wait()
        print(rcm_cmd)
        rcm_proc = subprocess.Popen(rcm_cmd, shell=True)
        rcm_proc.wait()
