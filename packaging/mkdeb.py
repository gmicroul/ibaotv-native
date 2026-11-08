#!/usr/bin/env python3
"""组装 .deb：本机 GNU tar 对多层相对路径会 ENOSYS 挂掉，
故 data/control 改用 Python tarfile 打包，再用 ar 组装。
用法：mkdeb.py <staging-dir> <输出.deb>"""
import os
import subprocess
import sys
import tarfile
import tempfile

SKIP_TOP = {'DEBIAN'}


def add_tree(tf, stage, arcbase):
    """递归加入，目录/文件/软链，属主统一 root:root。"""
    srcdir = os.path.join(stage, arcbase)
    for root, dirs, files in os.walk(srcdir):
        dirs.sort()
        rel = os.path.relpath(root, stage)
        arc = './' + rel
        ti = tf.gettarinfo(root, arc)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        tf.addfile(ti)
        for name in sorted(files):
            fsrc = os.path.join(root, name)
            farc = arc + '/' + name
            if os.path.islink(fsrc):
                ti = tarfile.TarInfo(farc)
                ti.type = tarfile.SYMTYPE
                ti.linkname = os.readlink(fsrc)
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = 'root'
                ti.mtime = int(os.lstat(fsrc).st_mtime)
                tf.addfile(ti)
                continue
            ti = tf.gettarinfo(fsrc, farc)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            # 可执行位保留原样，其余按常规补齐
            st = os.stat(fsrc)
            ti.mode = 0o755 if (st.st_mode & 0o111) else 0o644
            with open(fsrc, 'rb') as f:
                tf.addfile(ti, f)


def make_control_gz(stage, path):
    debdir = os.path.join(stage, 'DEBIAN')
    with tarfile.open(path, 'w:gz', format=tarfile.GNU_FORMAT) as tf:
        for name in sorted(os.listdir(debdir)):
            fsrc = os.path.join(debdir, name)
            if not os.path.isfile(fsrc):
                continue
            ti = tf.gettarinfo(fsrc, name)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            st = os.stat(fsrc)
            ti.mode = 0o755 if (st.st_mode & 0o111) else 0o644
            with open(fsrc, 'rb') as f:
                tf.addfile(ti, f)


def main():
    stage, deb = sys.argv[1], sys.argv[2]
    if os.path.exists(deb):
        os.remove(deb)  # 防旧残留（ar r 会保留同名外的老成员）
    tmp = tempfile.mkdtemp(prefix='hgdeb')
    debian_binary = os.path.join(tmp, 'debian-binary')
    control_gz = os.path.join(tmp, 'control.tar.gz')
    data_gz = os.path.join(tmp, 'data.tar.gz')
    with open(debian_binary, 'wb') as f:
        f.write(b'2.0\n')
    make_control_gz(stage, control_gz)
    with tarfile.open(data_gz, 'w:gz', format=tarfile.GNU_FORMAT) as tf:
        for top in sorted(os.listdir(stage)):
            if top in SKIP_TOP:
                continue
            if os.path.isdir(os.path.join(stage, top)):
                add_tree(tf, stage, top)
    subprocess.run(['ar', 'rcs', deb, debian_binary, control_gz, data_gz],
                   check=True)
    print('built', deb, os.path.getsize(deb), 'bytes')


if __name__ == '__main__':
    main()
