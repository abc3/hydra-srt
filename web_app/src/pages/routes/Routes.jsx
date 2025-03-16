import { useEffect, useState } from 'react';
import { Table, Card, Button, Tag, Space, Typography, message, Modal } from 'antd';
import { PlusOutlined, EditOutlined, DeleteOutlined, ExclamationCircleFilled, CaretRightOutlined, StopOutlined, HomeOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { routesApi } from '../../utils/api';

const { Title } = Typography;

const Routes = () => {
  const [routes, setRoutes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const navigate = useNavigate();

  // Set breadcrumb items for the Routes page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/routes',
          title: 'Routes',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchRoutes();
  }, []);

  const fetchRoutes = async () => {
    try {
      setLoading(true);
      const result = await routesApi.getAll();
      setRoutes(result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch routes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const showDeleteConfirm = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return handleDelete(record.id);
      },
    });
  };

  const handleDelete = async (id) => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      fetchRoutes(); // Refresh the list
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const handleRouteStatus = async (id, action) => {
    try {
      const result = action === 'start'
        ? await routesApi.start(id)
        : await routesApi.stop(id);

      // Update the specific route in the routes array
      setRoutes(routes.map(route =>
        route.id === id ? { ...route, status: result.data.status } : route
      ));

      messageApi.success(`Route ${action}ed successfully`);
    } catch (error) {
      messageApi.error(`Failed to ${action} route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const columns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      render: (text, record) => {
        return (
          <Space>
            <a href={`#/routes/${record.id}`}>
              {text}
            </a>
          </Space>
        )
      },
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      render: (schema) => (
        <Tag color={schema ? 'green' : 'gray'}>
          {schema ? 'yes' : 'no'}
        </Tag>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
    },
    {
      title: 'Authentication',
      key: 'authentication',
      // filters: [
      //   { text: 'Enabled', value: true },
      //   { text: 'Disabled', value: false }
      // ],
      // onFilter: (value, record) => {
      //   if (record.schema !== 'SRT') return !value;
      //   return (record.schema_options && record.schema_options.authentication) === value;
      // },
      render: (_, record) => {
        if (record.schema !== 'SRT') return <Tag color="default">N/A</Tag>;
        return record.schema_options && record.schema_options.authentication ? (
          <Tag color="green">yes</Tag>
        ) : (
          <Tag color="default">no</Tag>
        );
      },
    },
    {
      title: 'Input',
      dataIndex: 'input',
      key: 'input',
      render: (text, record) => {
        switch (record.schema) {
          case 'SRT':
            return (`${record.schema}:${record.srtMode}:${record?.schema_options?.localport}`);
          default:
            return ('Unknown');
        }
      }

    },
    {
      title: 'Last Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      render: (date) => new Date(date).toLocaleString(),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => (
        <Space>
          <Button
            type="link"
            icon={record.status === 'started' ? <StopOutlined /> : <CaretRightOutlined />}
            onClick={() => handleRouteStatus(record.id, record.status === 'started' ? 'stop' : 'start')}
          >
            {record.status === 'started' ? 'Stop' : 'Start'}
          </Button>
          <Button
            type="link"
            icon={<EditOutlined />}
            onClick={() => navigate(`/routes/${record.id}/edit`)}
          >
            Edit
          </Button>
          <Button
            type="link"
            danger
            icon={<DeleteOutlined />}
            onClick={() => showDeleteConfirm(record)}
          >
            Delete
          </Button>
        </Space>
      ),
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Routes</Title>
          <Space>
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => navigate('/routes/new/edit')}
            >
              Add Route
            </Button>
          </Space>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={routes}
            rowKey="id"
            loading={loading}
            pagination={{
              defaultPageSize: 10,
              showSizeChanger: true,
              showTotal: (total) => `Total ${total} routes`,
            }}
          />
        </Card>
      </Space>
    </div>
  );
};

export default Routes; 