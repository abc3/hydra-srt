import { useEffect, useState, useRef } from 'react';
import { Typography, Button, Card, Space, message, Tabs, Modal } from 'antd';
import { HomeOutlined, DownloadOutlined, UploadOutlined, ExclamationCircleOutlined, CheckCircleOutlined, CloseCircleOutlined } from '@ant-design/icons';
import { backupApi } from '../utils/api';

const { Title } = Typography;

const Settings = () => {
  const [activeTab, setActiveTab] = useState('backup');
  const [isDownloading, setIsDownloading] = useState(false);
  const [isRestoring, setIsRestoring] = useState(false);
  const [isDownloadingRoutes, setIsDownloadingRoutes] = useState(false);
  const fileInputRef = useRef(null);
  const [modal, modalContextHolder] = Modal.useModal();
  const [messageApi, contextHolder] = message.useMessage();

  // Set breadcrumb items for the Settings page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/settings',
          title: 'Settings',
        }
      ]);
    }
  }, []);

  const handleBackupDownload = async () => {
    setIsDownloading(true);
    try {
      await backupApi.downloadBackup();
      messageApi.success({
        content: 'Backup download started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error) {
      console.error('Error downloading backup:', error);
      messageApi.error({
        content: `Failed to download backup: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloading(false);
    }
  };

  const handleRoutesBackupDownload = async () => {
    setIsDownloadingRoutes(true);
    try {
      await backupApi.download();
      messageApi.success({
        content: 'Routes export started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error) {
      console.error('Error exporting routes:', error);
      messageApi.error({
        content: `Failed to export routes: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloadingRoutes(false);
    }
  };

  const handleFileChange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    if (!file.name.endsWith('.backup')) {
      messageApi.error({
        content: 'You can only upload .backup files!',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
      // Clear the file input
      if (fileInputRef.current) {
        fileInputRef.current.value = '';
      }
      return;
    }

    // Show confirmation dialog using the modal instance
    modal.confirm({
      title: 'Confirm Restore',
      icon: <ExclamationCircleOutlined />,
      content: (
        <>
          <p>Are you sure you want to restore from this backup?</p>
          <p>This will delete all existing data and replace it with the data from the backup file.</p>
          <p>Selected file: {file.name}</p>
        </>
      ),
      okText: 'Yes, Restore',
      cancelText: 'No, Cancel',
      okButtonProps: { danger: true },
      onOk: async () => {
        setIsRestoring(true);
        try {
          console.log('Starting restore process with file:', file.name);

          // Show loading notification
          messageApi.loading({
            content: `Restoring from backup: ${file.name}...`,
            key: 'restoreOperation',
            duration: 0 // 0 means it won't disappear automatically
          });

          const result = await backupApi.restore(file);
          console.log('Restore API response:', result);

          if (result && result.message) {
            messageApi.success({
              content: result.message,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation', // Use the same key to replace the loading message
              duration: 3
            });
          } else {
            messageApi.success({
              content: `${file.name} backup restored successfully`,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation',
              duration: 3
            });
          }
        } catch (error) {
          console.error('Error restoring backup:', error);

          let errorMessage = 'Failed to restore backup';
          if (error.response) {
            try {
              const errorData = await error.response.json();
              errorMessage = errorData.error || errorMessage;
            } catch (e) {
              console.error('Error parsing error response:', e);
            }
          } else if (error.message) {
            errorMessage = `${errorMessage}: ${error.message}`;
          }

          messageApi.error({
            content: errorMessage,
            icon: <CloseCircleOutlined />,
            key: 'restoreOperation', // Use the same key to replace the loading message
            duration: 5
          });
        } finally {
          setIsRestoring(false);
          // Clear the file input
          if (fileInputRef.current) {
            fileInputRef.current.value = '';
          }
        }
      },
      onCancel: () => {
        // Clear the file input
        if (fileInputRef.current) {
          fileInputRef.current.value = '';
        }
      }
    });
  };

  // Backup tab content
  const BackupTabContent = () => {
    return (
      <div>
        <Card title="System Backup" style={{ marginBottom: '16px' }}>
          <p>Create a backup of your system configuration and data.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleBackupDownload}
              loading={isDownloading}
            >
              Download Backup
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will create a complete backup of your system configuration.
            </p>
          </Space>
        </Card>

        <Card title="Restore from Backup">
          <p>Restore your system from a previous backup file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <input
              type="file"
              ref={fileInputRef}
              onChange={handleFileChange}
              style={{ display: 'none' }}
              accept=".backup"
              name="backup"
            />
            <Button
              icon={<UploadOutlined />}
              onClick={() => fileInputRef.current.click()}
              loading={isRestoring}
            >
              Select Backup File
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              Warning: Restoring from backup will overwrite your current configuration.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  // Routes tab content
  const RoutesTabContent = () => {
    return (
      <div>
        <Card title="Export Routes">
          <p>Export all routes and their destinations as a JSON file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleRoutesBackupDownload}
              loading={isDownloadingRoutes}
            >
              Export Routes as JSON
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will export a JSON file containing all routes with their destinations.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  const items = [
    {
      key: 'backup',
      label: 'Backup',
      children: <BackupTabContent />,
    },
    {
      key: 'routes',
      label: 'Routes',
      children: <RoutesTabContent />,
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>

        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Settings</Title>
        </Space>

        <Card>
          <Tabs
            activeKey={activeTab}
            onChange={setActiveTab}
            items={items}
            tabPosition="left"
          />
        </Card>
      </Space>
    </div>
  );
};

export default Settings; 