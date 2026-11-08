"""Isolated, cancellable download worker; never connects to a device."""
from .device import DeviceAdapter

if __name__ == "__main__":
    DeviceAdapter.download_ddi()
