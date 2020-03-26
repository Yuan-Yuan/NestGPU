#!/usr/bin/python
"""
   Copyright (c) 2012-2013 The Ohio State University.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
"""

import sys
import os
import config
from schema import global_table_dict as schema, process_schema_in_a_file, ColumnSchema, TableSchema

baseIndent = " " * 4

joinType = config.joinType
POS = config.POS
SOA = config.SOA
CODETYPE = config.CODETYPE

PID = config.PID
DTYPE = config.DTYPE

"""
generate_soa generates a python script that will help transform
data from AOS to SOA. This is only for comparing the performance
of SOA with AOS.
"""

def generate_soa():

    fo = open("soa.py","w")

    print >>fo, "#! /usr/bin/python"
    print >>fo, "import os\n"

    print >>fo, "cmd = \"\""
    for tn in schema.keys():
        attrLen = len(schema[tn].column_list)

        for i in range(0,attrLen):
            col = schema[tn].column_list[i]
            if col.column_type == "TEXT":
                print >>fo, "cmd = \"./soa " + tn + str(i) + " " + str(col.column_others) + "\""
                print >>fo, "os.system(cmd)"

    fo.close()
    os.system("chmod +x ./soa.py")

"""
generate_loader will generate the load.c which will transform
the row-stored text raw data into column-stored binary data.
"""

def generate_loader():

    indent = ""
    fo = open("load.c","w")

    print >>fo, "/* This file is generated by loader.py */"
    print >>fo, "#define _FILE_OFFSET_BITS       64"
    print >>fo, "#define _LARGEFILE_SOURCE"
    print >>fo, "#include <stdio.h>"
    print >>fo, "#include <stdlib.h>"
    print >>fo, "#include <error.h>"
    print >>fo, "#include <unistd.h>"
    print >>fo, "#include <string.h>"
    print >>fo, "#include <getopt.h>"
    print >>fo, "#include <time.h>"
    print >>fo, "#include <string.h>"
    print >>fo, "#include <linux/limits.h>"
    print >>fo, "#include \"../include/schema.h\""
    print >>fo, "#include \"../include/common.h\""
    print >>fo, "#define CHECK_POINTER(p) do {\\"
    indent += baseIndent
    print >>fo, indent + "if(p == NULL){   \\"
    indent += baseIndent
    print >>fo, indent + "perror(\"Failed to allocate host memory\");    \\"
    print >>fo, indent + "exit(-1);  \\"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}} while(0)"

    print >>fo, "static char delimiter = '|';\n"

    for tn in schema.keys():
        attrLen = len(schema[tn].column_list)

        print >>fo, "void " + tn.lower() + " (FILE *fp, char *outName){\n"

        indent = baseIndent
        print >>fo, indent + "struct " + tn.lower() + " tmp;"
        print >>fo, indent + "struct tm tm;"
        print >>fo, indent + "char data [1024] = {0};"
        print >>fo, indent + "char buf[1024] = {0};"
        print >>fo, indent + "int count = 0, i = 0,prev = 0;"
        print >>fo, indent + "long tupleCount =0, tupleRemain = 0, tupleUnit = 0;"
        print >>fo, indent + "FILE * out[" + str(attrLen) + "];\n"

        print >>fo, indent + "for(i=0;i<" + str(attrLen) + ";i++){"
        indent += baseIndent
        print >>fo, indent + "char path[PATH_MAX] = {0};"
        print >>fo, indent + "sprintf(path,\"%s%d\",outName,i);"
        print >>fo, indent + "out[i] = fopen(path, \"w\");"
        print >>fo, indent + "if(!out[i]){"
        indent += baseIndent
        print >>fo, indent + "printf(\"Failed to open %s\\n\",path);"
        print >>fo, indent + "exit(-1);"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}\n"

        print >>fo, indent + "struct columnHeader header;"
        print >>fo, indent + "long tupleNum = 0;"
        print >>fo, indent + "while(fgets(buf,sizeof(buf),fp) !=NULL)"
        indent += baseIndent
        print >>fo, indent + "tupleNum ++;\n"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "header.totalTupleNum = tupleNum;"
        print >>fo, indent + "tupleRemain = tupleNum;"

        print >>fo, indent + "if(tupleNum > BLOCKNUM)"
        indent += baseIndent
        print >>fo, indent + "tupleUnit = BLOCKNUM;"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "else"
        indent += baseIndent
        print >>fo, indent + "tupleUnit = tupleNum;"

        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "header.tupleNum = tupleUnit;"
        print >>fo, indent + "header.format = UNCOMPRESSED;"
        print >>fo, indent + "header.blockId = 0;"
        print >>fo, indent + "header.blockTotal = (tupleNum + BLOCKNUM -1) / BLOCKNUM ;"

        print >>fo, indent + "fseek(fp,0,SEEK_SET);"

        for i in range(0,attrLen):
            col = schema[tn].column_list[i]
            if col.column_type == "INTEGER" or col.column_type == "DATE":
                print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(int);"
            elif col.column_type == "DECIMAL":
                print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(float);"
            elif col.column_type == "TEXT":
                print >>fo, indent + "header.blockSize = header.tupleNum * " + str(col.column_others) + ";"

            print >>fo, indent + "fwrite(&header, sizeof(struct columnHeader), 1, out[" + str(i) + "]);"

        print >>fo, indent + "while(fgets(buf,sizeof(buf),fp)!= NULL){"

        indent += baseIndent
        print >>fo, indent + "int writeHeader = 0;"
        print >>fo, indent + "tupleCount ++;"
        print >>fo, indent + "if(tupleCount > BLOCKNUM){"
        indent += baseIndent
        print >>fo, indent + "tupleCount = 1;"
        print >>fo, indent + "tupleRemain -= BLOCKNUM;"
        print >>fo, indent + "if (tupleRemain > BLOCKNUM)"
        indent += baseIndent
        print >>fo, indent + "tupleUnit = BLOCKNUM;"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "else"
        indent += baseIndent
        print >>fo, indent + "tupleUnit = tupleRemain;"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "header.tupleNum = tupleUnit;"
        print >>fo, indent + "header.blockId ++;"
        print >>fo, indent + "writeHeader = 1;"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"

        print >>fo, indent + "for(i = 0, prev = 0,count=0; buf[i] !='\\n';i++){"
        indent += baseIndent
        print >>fo, indent + "if (buf[i] == delimiter){"
        indent += baseIndent
        print >>fo, indent + "memset(data,0,sizeof(data));"
        print >>fo, indent + "strncpy(data,buf+prev,i-prev);"
        print >>fo, indent + "prev = i+1;"
        print >>fo, indent + "switch(count){"

        for i in range(0,attrLen):
            col = schema[tn].column_list[i]
            print >>fo, indent + "case " + str(i) + ":"

            indent += baseIndent
            if col.column_type == "INTEGER":
                print >>fo, indent + "if(writeHeader == 1){"
                indent += baseIndent
                print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(int);"
                print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(i) + "]);"
                indent = indent[:indent.rfind(baseIndent)]
                print >>fo, indent + "}"
                print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = strtol(data,NULL,10);"
                print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(int),1,out["+str(i) + "]);"
            elif col.column_type == "DECIMAL":
                print >>fo, indent + "if(writeHeader == 1){"
                indent += baseIndent
                print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(float);"
                print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(i) + "]);"
                indent = indent[:indent.rfind(baseIndent)]
                print >>fo, indent + "}"
                print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = atof(data);"
                print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(float),1,out["+str(i) + "]);"
            elif col.column_type == "TEXT":
                print >>fo, indent + "if(writeHeader == 1){"
                indent += baseIndent
                print >>fo, indent + "header.blockSize = header.tupleNum * " + str(col.column_others) + ";"
                print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(i) + "]);"
                indent = indent[:indent.rfind(baseIndent)]
                print >>fo, indent + "}"
                print >>fo, indent + "strncpy(tmp." + str(col.column_name.lower()) + ",data,sizeof(tmp." + str(col.column_name.lower()) + "));"
                print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(tmp." +str(col.column_name.lower()) + "), 1, out[" + str(i) + "]);"
            elif col.column_type == "DATE":
                print >>fo, indent + "if(writeHeader == 1){"
                indent += baseIndent
                print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(int);"
                print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(i) + "]);"
                indent = indent[:indent.rfind(baseIndent)]
                print >>fo, indent + "}"
                print >>fo, indent + "memset(&tm, 0, sizeof(struct tm));"
                print >>fo, indent + "strptime(data, \"%Y-%m-%d\", &tm);"
                print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = mktime(&tm);"
                print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(int),1,out["+str(i) + "]);"

            print >>fo, indent + "break;"
            indent = indent[:indent.rfind(baseIndent)]

        print >>fo, indent + "}"
        print >>fo, indent + "count++;"

        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"

        print >>fo, indent + "if(count == " + str(attrLen-1) + "){"

        col = schema[tn].column_list[attrLen-1]
        indent += baseIndent
        if col.column_type == "INTEGER":
            print >>fo, indent + "if(writeHeader == 1){"
            indent += baseIndent
            print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(int);"
            print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(attrLen-1) + "]);"
            indent = indent[:indent.rfind(baseIndent)]
            print >>fo, indent + "}"
            print >>fo, indent + "memset(data,0,sizeof(data));"
            print >>fo, indent + "strncpy(data,buf+prev,i-prev);"
            print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = strtol(data,NULL,10);"
            print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(int),1,out["+str(attrLen-1) + "]);"
        elif col.column_type == "DECIMAL":
            print >>fo, indent + "if(writeHeader == 1){"
            indent += baseIndent
            print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(float);"
            print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(attrLen-1) + "]);"
            indent = indent[:indent.rfind(baseIndent)]
            print >>fo, indent + "}"
            print >>fo, indent + "memset(data,0,sizeof(data));"
            print >>fo, indent + "strncpy(data,buf+prev,i-prev);"
            print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = atof(data);"
            print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(float),1,out["+str(i) + "]);"
        elif col.column_type == "TEXT":
            print >>fo, indent + "if(writeHeader == 1){"
            indent += baseIndent
            print >>fo, indent + "header.blockSize = header.tupleNum * " + str(col.column_others) + ";"
            print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(attrLen-1) + "]);"
            indent = indent[:indent.rfind(baseIndent)]
            print >>fo, indent + "}"
            print >>fo, indent + "strncpy(tmp." + str(col.column_name.lower()) + ",buf+prev,i-prev);"
            print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(tmp." +str(col.column_name.lower()) + "), 1, out[" + str(attrLen-1) + "]);"
        elif col.column_type == "DATE":
            print >>fo, indent + "if(writeHeader == 1){"
            indent += baseIndent
            print >>fo, indent + "header.blockSize = header.tupleNum * sizeof(int);"
            print >>fo, indent + "fwrite(&header,sizeof(struct columnHeader),1,out[" + str(i) + "]);"
            indent = indent[:indent.rfind(baseIndent)]
            print >>fo, indent + "}"
            print >>fo, indent + "memset(&tm, 0, sizeof(struct tm));"
            print >>fo, indent + "strptime(data, \"%Y-%m-%d\", &tm);"
            print >>fo, indent + "tmp."+str(col.column_name.lower()) + " = mktime(&tm);"
            print >>fo, indent + "fwrite(&(tmp." + str(col.column_name.lower()) + "),sizeof(int),1,out["+str(attrLen-1) + "]);"

        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"

        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}\n" ### end of reading from input file

        print >>fo, indent + "for(i=0;i<" + str(attrLen) + ";i++){"
        indent += baseIndent
        print >>fo, indent + "fclose(out[i]);"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}\n"

    print >>fo, indent + "int main(int argc, char ** argv){\n"
    indent += baseIndent
    print >>fo, indent + "FILE * in = NULL, *out = NULL;"
    print >>fo, indent + "int table;"
    print >>fo, indent + "int setPath = 0;"
    print >>fo, indent + "char path[PATH_MAX];"
    print >>fo, indent + "char cwd[PATH_MAX];\n"
    print >>fo, indent + "int long_index;"

    print >>fo, indent + "struct option long_options[] = {"
    indent += baseIndent
    for i in range(0, len(schema.keys())):
        print >>fo, indent + "{\"" + schema.keys()[i].lower()+ "\",required_argument,0,'" + str(i) + "'},"

    print >>fo, indent + "{\"delimiter\",required_argument,0,'" +str(i+1) + "'},"
    print >>fo, indent + "{\"datadir\",required_argument,0,'" +str(i+2) + "'}"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "};\n"

    print >>fo, indent + "while((table=getopt_long(argc,argv,\"\",long_options,&long_index))!=-1){"
    indent += baseIndent
    print >>fo, indent + "switch(table){"
    print >>fo, indent + "case '" + str(i + 2) + "':"
    indent += baseIndent
    print >>fo, indent + "setPath = 1;"
    print >>fo, indent + "strcpy(path,optarg);"
    print >>fo, indent + "break;"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}\n"

    print >>fo, indent + "optind=1;\n"
    print >>fo, indent + "getcwd(cwd,PATH_MAX);"

    print >>fo, indent + "while((table=getopt_long(argc,argv,\"\",long_options,&long_index))!=-1){"
    indent += baseIndent
    print >>fo, indent + "switch(table){"
    for i in range(0, len(schema.keys())):
        print >>fo, indent + "case '" + str(i) + "':"
        indent += baseIndent
        print >>fo, indent + "in = fopen(optarg,\"r\");"
        print >>fo, indent + "if(!in){"
        indent += baseIndent
        print >>fo, indent + "printf(\"Failed to open %s\\n\",optarg);"
        print >>fo, indent + "exit(-1);"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        print >>fo, indent + "if (setPath == 1){"
        indent += baseIndent
        print >>fo, indent + "chdir(path);"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        print >>fo, indent + schema.keys()[i].lower() + "(in,\"" + schema.keys()[i] + "\");"
        print >>fo, indent + "if (setPath == 1){"
        indent += baseIndent
        print >>fo, indent + "chdir(cwd);"
        indent = indent[:indent.rfind(baseIndent)]
        print >>fo, indent + "}"
        print >>fo, indent + "fclose(in);"
        print >>fo, indent + "break;"
        indent = indent[:indent.rfind(baseIndent)]

    print >>fo, indent + "case '" + str(i+1) + "':"
    indent += baseIndent
    print >>fo, indent + "delimiter = optarg[0];"
    print >>fo, indent + "break;"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}"
    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}\n"

    print >>fo, indent + "return 0;"

    indent = indent[:indent.rfind(baseIndent)]
    print >>fo, indent + "}\n"

    fo.close()

"""
loader_code_gen: entry point for code generation.
"""

def loader_code_gen(argv):

    schemaFile = None
    if len(sys.argv) == 2:
        schemaFile = process_schema_in_a_file(argv[1])
    else:
        print "ERROR: usage: loader_gen.py $schema_file"
        exit(1)

    pwd = os.getcwd()
    resultDir = "./src"
    utilityDir = "./utility"

    os.chdir(pwd)
    os.chdir(resultDir)
    os.chdir(utilityDir)
    generate_loader()
    if SOA == 1:
        generate_soa()

    os.chdir(pwd)

if __name__ == '__main__':

    loader_code_gen(sys.argv)

