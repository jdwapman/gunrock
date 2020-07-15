import os
import sys
import numpy as np
import re

# Traverse into all subfolders
# If the subfolder contains a .DIR.txt or .UDIR.txt file, the dataset is the name of the folder
# Make a dict with [dataset][dir/udir][numpy array for the advance times]

top_results_dir = sys.argv[1]

advance_iteration_times = {} #[dataset, directed/undirected]
DIR = 0
UDIR = 1
num_runs = 3

# Given a directory, traverse the file tree and get the output files
# NOTE: There cannot be any subfolders within the dataset folder
for root, dirs, files in os.walk(top_results_dir):
    if dirs == []:
        file_udir = [i for i in files if '.UDIR.txt' in i][0]
        file_dir = [i for i in files if '.DIR.txt' in i][0]

        dataset = os.path.split(root)[-1]

        advance_iteration_times[dataset] = [[], []]

        with open(root + "/" + file_udir) as f:
            lines = f.readlines()
            for line in lines:
                if 'Advance Time' in line:
                    # There should be only one time per line
                    time = re.findall("\d+\.\d+",line)
                    advance_iteration_times[dataset][UDIR].append(time[0])

        with open(root + "/" + file_dir) as f:
            lines = f.readlines()
            for line in lines:
                if 'Advance Time' in line:
                    # There should be only one time per line
                    time = re.findall("\d+\.\d+",line)
                    advance_iteration_times[dataset][DIR].append(time[0])

        # Convert from lists to numpy arrays
        advance_iteration_times[dataset][UDIR] = np.array(advance_iteration_times[dataset][UDIR]).reshape((3,-1))
        advance_iteration_times[dataset][DIR] = np.array(advance_iteration_times[dataset][DIR]).reshape((3,-1))


        print(advance_iteration_times[dataset][UDIR])

