
"""
Module to expose more detailed version info for the installed `numpy`
"""
version = "2.3.5.post1"
__version__ = version
full_version = version

git_revision = "b94b927fb07c5eab659eecdbae18ba1d574bde4f"
release = 'dev' not in version and '+' not in version
short_version = version.split("+")[0]
