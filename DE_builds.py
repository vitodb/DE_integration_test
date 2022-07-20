#!/usr/bin/env python3

import re
import subprocess
import sys
import ast
import urllib.request, urllib.parse, urllib.error
import time
from datetime import datetime, date
import os
import csv
import io

class check_CI_builds:

    def __init__(self):
        self.jobname = 'decisionengine_pipeline'
        self.branch = 'master'
        self.buildmaster_url = 'https://buildmaster.fnal.gov/buildmaster'
        self.debug = False
        self.check = False
        self.time_limit = 200

    def parse_arguments(self):
        import optparse
        parser = optparse.OptionParser()

        parser.add_option(
            "-j",
            "--jobname",
            help="Set Jenkins job name",
            default='decisionengine_pipeline'
        )
        parser.add_option(
            "-b",
            "--branch",
            help="Set branch name",
            default='master'
        )
        parser.add_option(
            "-t",
            "--time_limit",
            help="Set time limit to use for CI builds to check on Jenkins",
            default = 200
        )
        parser.add_option(
            "-d",
            "--debug",
            action="store_true",
            help="Set debug flag",
            default=False
        )
        parser.add_option(
            "-c",
            "--check",
            action="store_true",
            help="Check if there are running builds",
            default=False
        )

        (self.options, self.args) = parser.parse_args()
        if self.options.debug:
            self.debug = self.options.debug
            print('debug', self.debug)

        if self.debug:
            print (self.options)
            print (self.args)

        if self.options.check:
            self.check = self.options.check
            if self.debug:
                print('check', self.check)

        if self.options.jobname:
            self.jobname = self.options.jobname
            if self.debug:
                print(self.jobname)

        if self.options.branch:
            self.branch = self.options.branch
            if self.debug:
                print(self.branch)

        if self.options.time_limit:
            self.time_limit = self.options.time_limit
            if self.debug:
                print(self.time_limit)

    def fetch_rpm(self, check):
        values = {}
        estatus = 0

        de_rpm_list = []
        de_rpm_url_list = []
        min_build_ETA = 1000
        time_fmt = '%Y/%m/%d %H:%M:%S'
        values = {}
        estatus = 0
        try:
            jobname_url = "{}/job/{}/api/python".format(self.buildmaster_url, self.jobname)
            jobname_data = ast.literal_eval(urllib.request.urlopen(jobname_url).read().decode())
        except urllib.error.HTTPError as e:
            # Return code error (e.g. 404, 501, ...)
            # ...
            estatus = e.code
            print('*** package: {}'.format(self.jobname))
            print('jobname_data HTTPError: {} for {}'.format(estatus, jobname_url))
            estatus = 1
            values.update({'status': estatus} )
            return {"key": "ERROR", "value": estatus, "values": values}
            #sys.exit(1)
        except urllib.error.URLError as e:
            # Not an HTTP-specific error (e.g. connection refused, onnection timed out ...)
            # ...
            estatus = e.reason
            print('*** package: {}'.format(self.jobname))
            print('jobname_data URLError: {} for {}'.format(estatus, jobname_url))
            estatus = 1
            values.update({'status': estatus} )
            return {"key": "ERROR", "value": estatus, "values": values}
            #sys.exit(1)
        if self.debug:
            print('### jobname_data:', jobname_data)
        for builds_list in jobname_data.get("builds"):
            if self.debug:
                print('@@@ builds_list:', builds_list)
            try:
                build_url = builds_list.get('url')+"/api/python"
                build_data = ast.literal_eval(urllib.request.urlopen(build_url).read().decode())
                branch_match = re.search(r'#{}'.format(self.branch), build_data.get("displayName"))
                estatus = 2
                values.update({'status': estatus} )
                if branch_match:
                    build_time = datetime.strptime(time.strftime(time_fmt, time.localtime(build_data.get("timestamp")/1000)), time_fmt)
                    now = datetime.now()
                    delta = (now - build_time).days
                    if delta > 0:
                        estatus = 3
                        values.update({'status': estatus} )
                        break
                    artifacts = build_data.get('artifacts')
                    if self.debug:
                        print('XXX build_data:', build_data)
                        print('XXX {} - {} - {} - {} - {}'.format(branch_match, build_data.get("fullDisplayName"), build_data.get("displayName"), build_data.get("result"), build_time))
                        print('artifacts:', artifacts)
                    de_rpm = [elem.get('relativePath') for elem in artifacts if re.search(r'noarch.rpm', elem.get('relativePath')) ]
                    if de_rpm:
                        de_rpm_url = builds_list.get('url')+"artifact/"+de_rpm[0]
                        de_rpm_list.append(de_rpm)
                        de_rpm_url_list.append(de_rpm_url)
                        print('\n*** MSG BEGIN ***\nRPM:\n CI build: {}\n name: {}\n build_time: {}\n url: {}\n*** MSG END ***\n'.format(build_data.get("fullDisplayName"), de_rpm, build_time, de_rpm_url))
                    print('Time info:\n now: {} - build_time: {} - delta days: {}\n'.format(now, build_time, delta))
                    ### we found our CI build, exit the builds_list loop
                    estatus = 0
                    values.update({'status': estatus} )
                    break

            except urllib.error.HTTPError as e:
                # Return code error (e.g. 404, 501, ...)
                # ...
                estatus = e.code
                print('*** package: {}'.format(self.jobname))
                print('builds_list HTTPError: {} for {}'.format(estatus, jobname_url))
                estatus = 1
                values.update({'status': estatus} )
                return {"key": "ERROR", "value": estatus, "values": values}
                #sys.exit(1)
            except urllib.error.URLError as e:
                # Not an HTTP-specific error (e.g. connection refused, onnection timed out ...)
                # ...
                estatus = e.reason
                print('*** package: {}'.format(self.jobname))
                print('builds_list URLError: {} for {}'.format(estatus, jobname_url))
                estatus = 1
                values.update({'status': estatus} )
                return {"key": "ERROR", "value": estatus, "values": values}
                #sys.exit(1)
            values.update({'building': False})
            if build_data.get('building'):
                timestamp = build_data.get('timestamp')
                build_ETA = build_data.get('estimatedDuration')/1000/60-(time.time()-timestamp/1000)/60
                min_build_ETA = min(min_build_ETA, build_ETA)
                values.update({'building': build_data.get('building')} )
                values.update({'build_number': build_data.get('number')} )
                values.update({'build_started_since': (time.time()-timestamp/1000)/60} )
                values.update({'build_ETA': build_ETA} )
                values.update({'estimate_duration': build_data.get('estimatedDuration')/1000/60} )

        if check:
            return {"values": values}

        if len(de_rpm_url_list) == 1:
            url = de_rpm_url_list[0]
            filename = url.split('/')[-1] # this will take only -1 splitted part of the url
            packagename = filename.split('-')[0]
            today = str(date.today())
            filename = filename.replace(packagename,packagename+'-'+self.branch+'-'+today)
            print('Downloading {} RPM: {}... {}'.format(self.jobname, filename, packagename))
            urllib.request.urlretrieve(url, filename)
            print('Download Completed!!!\n***\n')

        return {"de_rpm_list": de_rpm_list, "de_rpm_url_list": de_rpm_url_list, "values": values}


if __name__ == "__main__":
    cb = check_CI_builds()
    cb.parse_arguments()
    res_dict = cb.fetch_rpm(check=cb.check)
    if cb.check:
        print("this was a check")
    print(res_dict)

    sys.exit(res_dict.get('values').get('status'))
