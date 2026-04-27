import { useEffect, useMemo, useState } from 'react';
import {
  Form,
  Input,
  Card,
  Space,
  Button,
  message,
  Typography,
  Row,
  Col,
  Select,
} from 'antd';
import {
  SaveOutlined,
  ArrowLeftOutlined,
  HomeOutlined,
  LoadingOutlined,
} from '@ant-design/icons';
import { useLocation, useNavigate, useParams } from 'react-router-dom';
import { interfacesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;
const OTHER_OPTION = '__other__';

const InterfaceEdit = () => {
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const location = useLocation();
  const { id } = useParams();
  const [messageApi, contextHolder] = message.useMessage();
  const [loading, setLoading] = useState(id !== 'new');
  const [systemLoading, setSystemLoading] = useState(false);
  const [systemInterfaces, setSystemInterfaces] = useState([]);
  const [existingInterface, setExistingInterface] = useState(null);
  const [createPrefill, setCreatePrefill] = useState(null);

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.INTERFACES,
          title: 'Interfaces',
        },
        {
          title:
            id === 'new'
              ? 'New Interface'
              : loading
                ? (
                    <>
                      <LoadingOutlined style={{ marginRight: 8 }} />
                      Loading...
                    </>
                  )
                : `Edit ${existingInterface?.name || 'Interface'}`,
        },
      ]);
    }
  }, [id, loading, existingInterface]);

  useEffect(() => {
    fetchSystemInterfaces();
  }, []);

  useEffect(() => {
    if (id !== 'new') {
      return;
    }

    const query = new URLSearchParams(location.search);
    const sysName = query.get('sys_name');
    const ip = query.get('ip');
    const multicastSupported = query.get('multicast_supported');

    if (!sysName && !ip) {
      return;
    }

    setCreatePrefill({
      sys_name: sysName || '',
      ip: ip || '',
      multicast_supported: multicastSupported === 'true',
    });
  }, [id, location.search]);

  useEffect(() => {
    if (id === 'new') {
      return;
    }

    fetchInterface();
  }, [id]);

  useEffect(() => {
    if (!existingInterface) {
      return;
    }

    const knownNames = systemInterfaces.map((item) => item.sys_name);
    const selectorValue = knownNames.includes(existingInterface.sys_name)
      ? existingInterface.sys_name
      : OTHER_OPTION;

    form.setFieldsValue({
      name: existingInterface.name,
      ip: existingInterface.ip,
      sys_name: existingInterface.sys_name,
      sys_name_selector: selectorValue,
    });
  }, [existingInterface, systemInterfaces, form]);

  const systemInterfaceOptions = useMemo(
    () =>
      systemInterfaces.map((item) => ({
        label: `${item.sys_name} (${item.ip}) - ${
          item.multicast_supported ? 'multicast' : 'no multicast'
        }`,
        value: item.sys_name,
        ip: item.ip,
        multicast_supported: item.multicast_supported,
      })),
    [systemInterfaces],
  );

  useEffect(() => {
    if (id !== 'new' || !createPrefill) {
      return;
    }

    const known = systemInterfaces.some((item) => item.sys_name === createPrefill.sys_name);
    const selectorValue =
      createPrefill.sys_name && known ? createPrefill.sys_name : OTHER_OPTION;

    form.setFieldsValue({
      name: '',
      ip: createPrefill.ip,
      sys_name: createPrefill.sys_name,
      sys_name_selector: createPrefill.sys_name ? selectorValue : undefined,
    });
  }, [id, createPrefill, systemInterfaces, form]);

  const fetchSystemInterfaces = async () => {
    try {
      setSystemLoading(true);
      const result = await interfacesApi.getSystemInterfaces();
      setSystemInterfaces(Array.isArray(result.data) ? result.data : []);
    } catch (error) {
      messageApi.error(`Failed to fetch system interfaces: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setSystemLoading(false);
    }
  };

  const fetchInterface = async () => {
    try {
      setLoading(true);
      const result = await interfacesApi.getById(id);
      setExistingInterface(result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch interface data: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const handleBack = () => {
    navigate(ROUTES.INTERFACES);
  };

  const handleSysNameSelectorChange = (value) => {
    if (value === OTHER_OPTION) {
      return;
    }

    const selected = systemInterfaceOptions.find((item) => item.value === value);
    const currentIp = form.getFieldValue('ip');

    form.setFieldsValue({
      sys_name: value,
      ip: selected?.ip || currentIp,
    });
  };

  const handleSave = () => {
    form.validateFields()
      .then(async (values) => {
        const sysName =
          values.sys_name_selector === OTHER_OPTION ? values.sys_name : values.sys_name_selector;

        const payload = {
          name: values.name,
          sys_name: sysName,
          ip:
            values.sys_name_selector !== OTHER_OPTION
              ? systemInterfaceOptions.find((item) => item.value === values.sys_name_selector)?.ip ||
                values.ip
              : values.ip,
        };

        const loadingMessage = messageApi.loading('Saving interface...', 0);

        try {
          if (id === 'new') {
            await interfacesApi.create(payload);
          } else {
            await interfacesApi.update(id, payload);
          }

          loadingMessage();
          messageApi.success('Interface saved successfully');
          navigate(ROUTES.INTERFACES);
        } catch (error) {
          loadingMessage();
          messageApi.error(`Failed to save interface: ${error.message}`);
          console.error('Error:', error);
        }
      })
      .catch(() => {
        messageApi.error('Please check the form for errors');
      });
  };

  return (
    <div>
      {contextHolder}
      <Form
        form={form}
        layout="vertical"
        initialValues={{
          name: '',
          ip: '',
          sys_name: '',
          sys_name_selector: undefined,
        }}
      >
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Space align="center" size="middle">
            <Button icon={<ArrowLeftOutlined />} onClick={handleBack}>
              Back
            </Button>
            <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
              {id === 'new' ? 'Add Interface' : 'Edit Interface'}
            </Title>
          </Space>

          <Row gutter={24}>
            <Col style={{ width: '100%', maxWidth: '1000px' }}>
              <Card title="Interface Options" size="small" loading={loading}>
                <Form.Item
                  label="Name"
                  name="name"
                  required
                  rules={[{ required: true, message: 'Please enter an interface name' }]}
                >
                  <Input placeholder="e.g. ISP-1" />
                </Form.Item>

                <Form.Item
                  label="System Interface"
                  name="sys_name_selector"
                  required
                  rules={[{ required: true, message: 'Please select a system interface' }]}
                >
                  <Select
                    placeholder="Select interface from system list"
                    loading={systemLoading}
                    options={[
                      ...systemInterfaceOptions,
                      { label: 'Other (enter manually)', value: OTHER_OPTION },
                    ]}
                    onChange={handleSysNameSelectorChange}
                  />
                </Form.Item>

                <Form.Item noStyle dependencies={['sys_name_selector']}>
                  {({ getFieldValue }) =>
                    getFieldValue('sys_name_selector') === OTHER_OPTION ? (
                      <Form.Item
                        label="System Name (manual)"
                        name="sys_name"
                        required
                        rules={[{ required: true, message: 'Please enter a system interface name' }]}
                      >
                        <Input placeholder="e.g. eno1" />
                      </Form.Item>
                    ) : null
                  }
                </Form.Item>

                <Form.Item noStyle dependencies={['sys_name_selector']}>
                  {({ getFieldValue }) => {
                    const selector = getFieldValue('sys_name_selector');
                    const selected = systemInterfaceOptions.find((item) => item.value === selector);

                    if (!selected) {
                      return null;
                    }

                    return (
                      <Typography.Text type={selected.multicast_supported ? 'success' : 'warning'}>
                        Multicast: {selected.multicast_supported ? 'supported' : 'not supported'}
                      </Typography.Text>
                    );
                  }}
                </Form.Item>

                <Form.Item noStyle dependencies={['sys_name_selector']}>
                  {({ getFieldValue }) => (
                    <Form.Item
                      label="IP"
                      name="ip"
                      required
                      rules={[{ required: true, message: 'Please enter an interface IP' }]}
                      extra="Keep CIDR if needed, e.g. 172.20.20.12/24"
                    >
                      <Input
                        placeholder="e.g. 172.20.20.12/24"
                        disabled={
                          !!getFieldValue('sys_name_selector') &&
                          getFieldValue('sys_name_selector') !== OTHER_OPTION
                        }
                      />
                    </Form.Item>
                  )}
                </Form.Item>
              </Card>
            </Col>
          </Row>

          <Row justify="end">
            <Space>
              <Button icon={<ArrowLeftOutlined />} onClick={handleBack}>
                Back
              </Button>
              <Button type="primary" icon={<SaveOutlined />} onClick={handleSave}>
                Save
              </Button>
            </Space>
          </Row>
        </Space>
      </Form>
    </div>
  );
};

export default InterfaceEdit;
